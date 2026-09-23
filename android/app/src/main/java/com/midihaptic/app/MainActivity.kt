package com.midihaptic.app

import android.content.Intent
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.midihaptic.app.audio.BeatDetector
import com.midihaptic.app.audio.MidiParser
import com.midihaptic.app.haptics.ClickPlayer
import com.midihaptic.app.haptics.HapticEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class Track(val uri: Uri, val name: String, val isAudio: Boolean)

val LOOP_NAMES = arrayOf("выбранное", "весь список", "🔂 повтор одного", "🔁 повтор всего")
val MAP_NAMES = arrayOf("velocity", "pitch", "drums")

class MainActivity : ComponentActivity() {

    private lateinit var haptics: HapticEngine
    private var mediaPlayer: MediaPlayer? = null
    private var playJob: Job? = null

    // состояние UI (живёт в activity, переживает рекомпозиции)
    private val playlist = mutableStateListOf<Track>()
    private val logLines = mutableStateListOf<String>()
    private var selected by mutableStateOf(0)
    private var mapMode by mutableStateOf(0)
    private var loopMode by mutableStateOf(0)
    private var tempoPct by mutableStateOf(100f)
    private var gainPct by mutableStateOf(100f)
    private var sensPct by mutableStateOf(100f)
    private var boostPct by mutableStateOf(150f)
    private var hapticOffsetMs by mutableStateOf(0f)
    private var metroBpm by mutableStateOf(120f)
    private var metroBeats by mutableStateOf(4)
    private var metroSound by mutableStateOf(true)
    private var metroOn by mutableStateOf(false)
    private var metroBeat by mutableStateOf(-1)
    private val clickPlayer by lazy {
        ClickPlayer(getSystemService(AudioManager::class.java))
    }
    private var metroJob: Job? = null
    private var withSound by mutableStateOf(true)
    private var playing by mutableStateOf(false)
    private var busyAnalyzing by mutableStateOf(false)
    private var progress by mutableStateOf(0f)
    private var timeText by mutableStateOf("")
    private var nowPlaying by mutableStateOf("")

    private val scope = kotlinx.coroutines.MainScope()

    private val picker = registerForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments()
    ) { uris -> addUris(uris) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        haptics = HapticEngine(this)
        log("вибромотор: ${if (haptics.hasVibrator) "есть" else "НЕ НАЙДЕН"}, " +
                "амплитуда: ${if (haptics.amplitudeControl) "да" else "нет"}")
        android.util.Log.i("HapticMidi",
            "started vibrator=${haptics.hasVibrator} amp=${haptics.amplitudeControl}")
        setContent { AppUi() }
        handleViewIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleViewIntent(intent)
    }

    override fun onDestroy() {
        metroStop()
        stopAll()
        clickPlayer.release()
        scope.cancel()
        super.onDestroy()
    }

    // ---------- файлы ----------

    private fun displayName(uri: Uri): String {
        if (uri.scheme == "file") {
            return uri.lastPathSegment ?: "файл"
        }
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) {
                    return c.getString(idx) ?: "файл"
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment ?: "файл"
    }

    /** Читает весь файл: content:// через resolver, file:// напрямую. null при ошибке. */
    private fun readAllBytes(uri: Uri): ByteArray? {
        return try {
            if (uri.scheme == "file") {
                java.io.File(uri.path ?: return null).readBytes()
            } else {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun isAudioName(name: String): Boolean {
        val n = name.lowercase()
        return n.endsWith(".mp3") || n.endsWith(".wav") || n.endsWith(".m4a") ||
                n.endsWith(".ogg") || n.endsWith(".flac") || n.endsWith(".aac")
    }

    private fun addUris(uris: List<Uri>) {
        var added = 0
        for (u in uris) {
            try {
                contentResolver.takePersistableUriPermission(
                    u, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
            if (playlist.any { it.uri == u }) continue
            val name = displayName(u)
            playlist.add(Track(u, name, isAudioName(name)))
            added++
        }
        if (added > 0) {
            selected = playlist.size - 1
            log("добавлено: $added, всего: ${playlist.size}")
        }
    }

    private fun handleViewIntent(intent: Intent?) {
        val u = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW) return
        addUris(listOf(u))
        if (!playing) play()
    }

    // ---------- лог ----------

    private fun log(s: String) {
        logLines.add(s)
        if (logLines.size > 200) logLines.removeAt(0)
    }

    // ---------- воспроизведение ----------

    private fun effVel(vel: Int): Int =
        ((vel * gainPct / 100f).toInt()).coerceIn(1, 127)

    private suspend fun checkActive() = currentCoroutineContext().ensureActive()

    /** Позиция звука, мс. null — звука нет или плеер умер. */
    private fun playerPos(): Long? =
        try { mediaPlayer?.currentPosition?.toLong() } catch (_: Exception) { null }

    /** сила 0..1 для вибрации (маппинг как в midi_haptic, но в амплитуду) */
    private fun strengthFor(midi: Int, vel: Int, ch: Int): Double {
        val v = effVel(vel)
        return when (mapMode) {
            1 -> { // pitch: низкие сильнее
                val base = when {
                    midi < 36 -> 1.0
                    midi < 48 -> 0.9
                    midi < 60 -> 0.65
                    midi < 72 -> 0.45
                    else -> 0.35
                }
                (base * (0.4 + 0.6 * v / 127.0)).coerceIn(0.05, 1.0)
            }
            2 -> { // drums: 10-й канал акцентами
                if (ch == 9) {
                    when (midi) {
                        35, 36 -> 1.0
                        38, 40 -> 0.9
                        else -> (v / 127.0 * 0.8).coerceIn(0.05, 1.0)
                    }
                } else v / 127.0
            }
            else -> v / 127.0
        }
    }

    fun play() {
        if (playing || busyAnalyzing) return
        if (playlist.isEmpty()) {
            log("список пуст — выбери файлы")
            return
        }
        val queue: List<Track> = when (loopMode) {
            1, 3 -> playlist.toList()
            else -> listOf(playlist[selected.coerceIn(playlist.indices)])
        }
        playJob = scope.launch {
            playing = true
            haptics.boost = boostPct / 100f
            var idx = 0
            try {
                while (true) {
                    ensureActive()
                    if (idx >= queue.size) {
                        if (loopMode == 3 && queue.size > 1) idx = 0
                        else break
                    }
                    playOne(queue[idx], idx, queue.size)
                    if (loopMode == 2) {
                        // повтор одного — тот же трек заново
                    } else {
                        idx++
                    }
                }
                log("⏹ очередь готова")
            } catch (_: kotlinx.coroutines.CancellationException) {
                log("■ остановлено")
            } finally {
                playing = false
                nowPlaying = ""
                progress = 0f
                timeText = ""
            }
        }
    }

    private suspend fun playOne(track: Track, idx: Int, total: Int) {
        nowPlaying = "▶ ${track.name} (${idx + 1}/$total)"
        log(nowPlaying)
        val tempo = tempoPct / 100f
        if (track.isAudio) {
            // --- MP3/WAV: анализ битов, потом звук + вибрация ---
            busyAnalyzing = true
            log("анализирую биты…")
            val beats = withContext(Dispatchers.Default) {
                BeatDetector.analyze(
                    this@MainActivity, track.uri,
                    sens = sensPct / 100.0, maxHits = 0
                )
            }
            busyAnalyzing = false
            if (beats.isEmpty()) {
                log("биты не найдены — попробуй поднять чуйку")
                return
            }
            val dur = beats.last().timeSec + 1.0
            log("битов: ${beats.size}, ${(beats.size / dur * 10).toInt() / 10.0} уд/с")
            android.util.Log.i("HapticMidi", "beats=${beats.size} dur=$dur")
            startSound(track.uri, tempo)
            val useClock = withSound && mediaPlayer != null
            val t0 = SystemClock.uptimeMillis()
            val totalMs = (dur * 1000 / tempo).toLong()
            for (b in beats) {
                val at = (b.timeSec * 1000 / tempo).toLong() + hapticOffsetMs.toLong()
                if (useClock) {
                    // ждём реальную позицию звука — вибрация привязана к аудио,
                    // а не к часам: звук не убегает вперёд
                    while (true) {
                        checkActive()
                        val pos = playerPos()
                        if (pos == null || pos >= at) break
                        delay(10)
                    }
                } else {
                    val wait = t0 + at - SystemClock.uptimeMillis()
                    if (wait > 0) delay(wait)
                    checkActive()
                }
                haptics.tap((b.strength * gainPct / 100f).coerceIn(0.0, 1.0))
                updateProgress(
                    if (useClock) playerPos() ?: (SystemClock.uptimeMillis() - t0)
                    else (SystemClock.uptimeMillis() - t0),
                    totalMs
                )
            }
            if (useClock) {
                // доигрываем хвост по часам звука (+4 с запаса, чтобы не висеть)
                var spins = 0
                while ((playerPos() ?: totalMs) < totalMs && spins < totalMs / 100 + 40) {
                    checkActive()
                    delay(100)
                    spins++
                }
            } else {
                val tail = t0 + totalMs - SystemClock.uptimeMillis()
                if (tail > 0) delay(tail)
            }
        } else {
            // --- MIDI: парсинг, потом звук + вибрация ---
            val bytes = withContext(Dispatchers.IO) { readAllBytes(track.uri) }
            if (bytes == null) {
                log("не могу прочитать файл")
                return
            }
            val song = try {
                MidiParser.parse(bytes)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                log("не MIDI: ${e.message}")
                return
            }
            log("нот: ${song.notes.size}, ${"%.1f".format(song.durationSec)} c")
            android.util.Log.i("HapticMidi", "notes=${song.notes.size} dur=${song.durationSec}")
            startSound(track.uri, tempo)
            val useClock = withSound && mediaPlayer != null
            val t0 = SystemClock.uptimeMillis()
            val totalMs = (song.durationSec * 1000 / tempo).toLong()
            for (n in song.notes) {
                val at = (n.timeSec * 1000 / tempo).toLong() + hapticOffsetMs.toLong()
                if (useClock) {
                    // ждём реальную позицию звука — вибрация привязана к аудио
                    while (true) {
                        checkActive()
                        val pos = playerPos()
                        if (pos == null || pos >= at) break
                        delay(10)
                    }
                } else {
                    val wait = t0 + at - SystemClock.uptimeMillis()
                    if (wait > 0) delay(wait)
                    checkActive()
                }
                haptics.tap(strengthFor(n.midi, n.vel, n.ch))
                updateProgress(
                    if (useClock) playerPos() ?: (SystemClock.uptimeMillis() - t0)
                    else (SystemClock.uptimeMillis() - t0),
                    totalMs
                )
            }
            if (useClock) {
                var spins = 0
                while ((playerPos() ?: totalMs) < totalMs && spins < totalMs / 100 + 40) {
                    checkActive()
                    delay(100)
                    spins++
                }
            } else {
                val tail = t0 + totalMs - SystemClock.uptimeMillis()
                if (tail > 0) delay(tail)
            }
        }
        stopSound()
        haptics.cancel()
    }

    private fun updateProgress(elapsedMs: Long, totalMs: Long) {
        if (totalMs <= 0) return
        progress = (elapsedMs.toFloat() / totalMs).coerceIn(0f, 1f)
        timeText = "${fmt(elapsedMs)} / ${fmt(totalMs)}"
    }

    private fun fmt(ms: Long): String {
        val s = (ms / 1000).toInt().coerceAtLeast(0)
        return "${s / 60}:${"%02d".format(s % 60)}"
    }

    private fun startSound(uri: Uri, tempo: Float) {
        stopSound()
        if (!withSound) return
        try {
            val mp = MediaPlayer()
            mp.setDataSource(this, uri)
            mp.prepare()
            try {
                mp.playbackParams = mp.playbackParams.setSpeed(tempo)
            } catch (_: Exception) {
            }
            mp.start()
            mediaPlayer = mp
            log("🔊 звук включён")
        } catch (e: Exception) {
            log("🔊 без звука (${e.message}) — только вибрация")
        }
    }

    private fun stopSound() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        mediaPlayer = null
    }

    fun stopAll() {
        playJob?.cancel()
        playJob = null
        stopSound()
        haptics.cancel()
        busyAnalyzing = false
    }

    private suspend fun delayUntil(t: Long) {
        val w = t - SystemClock.uptimeMillis()
        if (w > 0) delay(w)
    }

    // ----- метроном (инструмент подгонки синхрона) -----
    // Клик звучит ровно в долю, вибрация — в долю + сдвиг «Синхрон».
    // Сдвиг читается каждую долю, так что крутить можно прямо во время стука.

    fun metroToggle() {
        if (metroOn) metroStop() else metroStart()
    }

    private fun metroStart() {
        if (playing || busyAnalyzing) return
        haptics.boost = boostPct / 100f
        metroOn = true
        metroJob = scope.launch {
            android.util.Log.i("HapticMidi", "metro start bpm=${metroBpm.toInt()}")
            log("метроном: ${metroBpm.toInt()} BPM, крути «Синхрон» до совпадения")
            log("медиа-громкость: ${clickPlayer.musicVolume()} (если 0 — клика не слышно)")
            val interval = 60000.0 / metroBpm
            var n = 0
            val t0 = SystemClock.uptimeMillis() + 300
            try {
                while (true) {
                    ensureActive()
                    val accent = (n % metroBeats == 0)
                    val soundAt = t0 + (n * interval).toLong()
                    val tapAt = soundAt + hapticOffsetMs.toLong()
                    val strong = if (accent) 1.0 else 0.45
                    if (tapAt <= soundAt) {
                        delayUntil(tapAt)
                        haptics.tap(strong)
                        delayUntil(soundAt)
                        if (metroSound) clickPlayer.play(accent)
                    } else {
                        delayUntil(soundAt)
                        if (metroSound) clickPlayer.play(accent)
                        delayUntil(tapAt)
                        haptics.tap(strong)
                    }
                    metroBeat = (n % metroBeats) + 1
                    n++
                }
            } catch (_: kotlinx.coroutines.CancellationException) {
            } finally {
                metroOn = false
                metroBeat = -1
            }
        }
    }

    fun metroStop() {
        metroJob?.cancel()
        metroJob = null
        metroOn = false
        haptics.cancel()
    }

    /** 5 пар «клик + вибрация» для быстрой проверки сдвига. */
    fun syncTest() {
        if (playing || metroOn || busyAnalyzing) return
        haptics.boost = boostPct / 100f
        scope.launch {
            try {
                log("тест синхрона: 5 пар, сдвиг ${hapticOffsetMs.toInt()} мс")
                repeat(5) {
                    ensureActive()
                    val base = SystemClock.uptimeMillis() + 400
                    val tapAt = base + hapticOffsetMs.toLong()
                    val first = minOf(base, tapAt)
                    val second = maxOf(base, tapAt)
                    delayUntil(first)
                    if (tapAt <= base) haptics.tap(1.0) else clickPlayer.play()
                    delayUntil(second)
                    if (tapAt <= base) clickPlayer.play() else haptics.tap(1.0)
                    delay(650)
                }
                log("готово: подкрути «Синхрон» и повтори")
            } catch (_: kotlinx.coroutines.CancellationException) {
            }
        }
    }

    // ---------- UI ----------

    @androidx.compose.runtime.Composable
    private fun AppUi() {
        val logScroll = rememberScrollState()
        MaterialTheme {
            Surface(Modifier.fillMaxSize()) {
                Column(
                    Modifier.fillMaxSize().verticalScroll(logScroll).padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text("Haptic MIDI + MP3", style = MaterialTheme.typography.titleLarge)
                    Text(
                        "Ноты и биты — в вибромотор. Держи телефон в руке.",
                        style = MaterialTheme.typography.bodySmall
                    )

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = { picker.launch(arrayOf("*/*")) },
                            enabled = !playing && !busyAnalyzing
                        ) { Text("Выбрать") }
                        Button(onClick = { play() }, enabled = !playing && !busyAnalyzing) {
                            Text("▶ Играть")
                        }
                        OutlinedButton(onClick = { stopAll() }, enabled = playing) {
                            Text("■ Стоп")
                        }
                        OutlinedButton(onClick = {
                            haptics.test()
                            log("тест: тук")
                        }) { Text("Тест") }
                    }

                    if (playlist.isNotEmpty()) {
                        Text("Режим: ${LOOP_NAMES[loopMode]}")
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            LOOP_NAMES.forEachIndexed { i, name ->
                                OutlinedButton(
                                    onClick = { loopMode = i },
                                    enabled = !playing,
                                    modifier = Modifier.weight(1f)
                                ) {
                                    Text(
                                        if (i < 2) name else name.substringAfter(" "),
                                        fontSize = 11.sp
                                    )
                                }
                            }
                        }
                    }

                    Text("Маппинг: ${MAP_NAMES[mapMode]}")
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        MAP_NAMES.forEachIndexed { i, name ->
                            OutlinedButton(
                                onClick = { mapMode = i },
                                modifier = Modifier.weight(1f)
                            ) { Text(name, fontSize = 12.sp) }
                        }
                    }

                    SliderRow("Громкость", "${gainPct.toInt()}%", 10f..200f, { gainPct }) {
                        gainPct = it
                    }
                    SliderRow("Темп", "x${"%.2f".format(tempoPct / 100f)}", 50f..200f, { tempoPct }) {
                        tempoPct = it
                    }
                    SliderRow("Чуйка (mp3)", "${sensPct.toInt()}%", 10f..200f, { sensPct }) {
                        sensPct = it
                    }
                    SliderRow("Буст", "${boostPct.toInt()}%", 100f..300f, { boostPct }) {
                        boostPct = it
                    }
                    SliderRow(
                        "Синхрон", "${hapticOffsetMs.toInt()} мс",
                        -1000f..1000f, { hapticOffsetMs }
                    ) {
                        hapticOffsetMs = it
                    }

                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(checked = withSound, onCheckedChange = { withSound = it })
                        Text("звук вместе с вибрацией")
                    }

                    Text("Метроном — для подгонки синхрона")
                    Text(
                        "Слушай клик и чувствуй вибрацию. Крути «Синхрон» выше, " +
                                "пока не совпадут. Сдвиг применяется вживую.",
                        style = MaterialTheme.typography.bodySmall
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${metroBpm.toInt()} BPM",
                            modifier = Modifier.width(90.dp),
                            fontSize = 15.sp
                        )
                        Slider(
                            value = metroBpm,
                            onValueChange = { metroBpm = it },
                            valueRange = 40f..240f,
                            modifier = Modifier.weight(1f)
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Доли:", fontSize = 13.sp)
                        Spacer(Modifier.width(8.dp))
                        listOf(2, 3, 4).forEach { b ->
                            OutlinedButton(onClick = { metroBeats = b }) {
                                Text("$b", fontSize = 12.sp)
                            }
                            Spacer(Modifier.width(6.dp))
                        }
                        Checkbox(
                            checked = metroSound,
                            onCheckedChange = { metroSound = it })
                        Text("клик", fontSize = 13.sp)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = { metroToggle() },
                            enabled = !playing && !busyAnalyzing
                        ) { Text(if (metroOn) "■ Метроном стоп" else "▶ Метроном") }
                        OutlinedButton(
                            onClick = { syncTest() },
                            enabled = !playing && !metroOn && !busyAnalyzing
                        ) { Text("Тест: 5 пар") }
                    }
                    if (metroOn) {
                        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            repeat(metroBeats) { i ->
                                val isCur = (i + 1 == metroBeat)
                                Text(
                                    if (i == 0) "●" else "○",
                                    color = if (isCur)
                                        MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurface
                                        .copy(alpha = 0.3f),
                                    fontSize = if (isCur) 30.sp else 22.sp
                                )
                            }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Точная подгонка:", fontSize = 13.sp)
                        Spacer(Modifier.width(8.dp))
                        OutlinedButton(onClick = {
                            hapticOffsetMs = (hapticOffsetMs - 10f).coerceIn(-1000f, 1000f)
                        }) { Text("−10 мс", fontSize = 12.sp) }
                        Spacer(Modifier.width(6.dp))
                        OutlinedButton(onClick = {
                            hapticOffsetMs = (hapticOffsetMs + 10f).coerceIn(-1000f, 1000f)
                        }) { Text("+10 мс", fontSize = 12.sp) }
                    }

                    if (nowPlaying.isNotEmpty()) {
                        Text(nowPlaying, style = MaterialTheme.typography.bodyMedium)
                        LinearProgressIndicator(
                            progress = { progress },
                            modifier = Modifier.fillMaxWidth()
                        )
                        Text(timeText, fontSize = 12.sp)
                    }

                    Text("Плейлист (${playlist.size}):")
                    Box(Modifier.fillMaxWidth().height(180.dp)) {
                        LazyColumn {
                            itemsIndexed(playlist, key = { _, t -> t.uri.toString() }) { i, t ->
                                val prefix = if (t.isAudio) "🔊 " else "🎹 "
                                Text(
                                    prefix + t.name,
                                    modifier = Modifier.fillMaxWidth()
                                        .clickable {
                                            selected = i
                                            if (!playing) play()
                                        }
                                        .padding(6.dp),
                                    color = if (i == selected)
                                        MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurface,
                                    fontSize = 13.sp
                                )
                            }
                        }
                    }

                    Text("Лог:")
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        logLines.takeLast(60).forEach {
                            Text(it, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                        }
                    }
                    Spacer(Modifier.height(20.dp))
                }
            }
        }
    }

    @androidx.compose.runtime.Composable
    private fun SliderRow(
        label: String,
        valueText: String,
        range: ClosedFloatingPointRange<Float>,
        get: () -> Float,
        onChange: (Float) -> Unit,
    ) {
        var v by remember(label) { mutableStateOf(get()) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, modifier = Modifier.width(110.dp), fontSize = 13.sp)
            Slider(
                value = v,
                onValueChange = {
                    v = it
                    onChange(it)
                },
                valueRange = range,
                modifier = Modifier.weight(1f)
            )
            Text(valueText, modifier = Modifier.width(72.dp), fontSize = 12.sp)
        }
    }
}
