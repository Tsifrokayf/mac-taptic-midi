package com.midihaptic.app.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteOrder
import kotlin.math.max

/** Удар: время в секундах и сила 0..1. */
data class Beat(val timeSec: Double, val strength: Double)

data class Pcm(val samples: ShortArray, val rate: Int)

/**
 * Декодирует аудио (mp3/m4a/wav/...) в PCM через MediaCodec
 * и ищет биты: energy flux + адаптивный порог. Порт audio_haptic.c.
 */
object BeatDetector {

    suspend fun analyze(
        context: Context,
        uri: Uri,
        sens: Double = 1.0,
        minGapSec: Double = 0.09,
        maxHits: Int = 0,
    ): List<Beat> = withContext(Dispatchers.Default) {
        try {
            val pcm = decodeMono16(context, uri) ?: return@withContext emptyList()
            detect(pcm.samples, pcm.rate, sens, minGapSec, maxHits)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun decodeMono16(context: Context, uri: Uri): Pcm? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, uri, null)
        } catch (e: Exception) {
            extractor.release()
            return null
        }
        var track = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                track = i
                format = f
                break
            }
        }
        if (track < 0 || format == null) {
            extractor.release()
            return null
        }
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val sampleRate = if (format.containsKey(MediaFormat.KEY_SAMPLE_RATE))
            format.getInteger(MediaFormat.KEY_SAMPLE_RATE) else 44100
        var channels = if (format.containsKey(MediaFormat.KEY_CHANNEL_COUNT))
            format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) else 2

        extractor.selectTrack(track)
        val codec = MediaCodec.createDecoderByType(mime)
        // просим 16-битный PCM
        try {
            codec.configure(format, null, null, 0)
        } catch (e: Exception) {
            codec.release()
            extractor.release()
            return null
        }
        codec.start()

        val out = ArrayList<Short>(1 shl 20)
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        // временный буфер под один входной чанк
        val inBuf = ByteArray(64 * 1024)
        try {
            while (!outputDone) {
                if (!inputDone) {
                    val idx = codec.dequeueInputBuffer(10_000)
                    if (idx >= 0) {
                        val buf = codec.getInputBuffer(idx)!!
                        buf.clear()
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(idx, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(idx, 0, n,
                                extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val idx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    idx >= 0 -> {
                        if (info.size > 0) {
                            val buf = codec.getOutputBuffer(idx)!!
                            // формат выхода может уточниться позже — читаем как есть
                            val shorts = buf.order(ByteOrder.nativeOrder()).asShortBuffer()
                            val total = info.size / 2
                            val ch = max(channels, 1)
                            var s = 0
                            while (s + ch <= total) {
                                var acc = 0
                                repeat(ch) { acc += shorts.get() }
                                out.add((acc / ch).toShort())
                                s += ch
                            }
                        }
                        codec.releaseOutputBuffer(idx, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        if (f.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }
                    }
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (inputDone) {
                            // вход кончился, а выхода нет — выходим чтобы не висеть
                            // (даём ещё пару попыток через счётчик ниже)
                        }
                    }
                }
                // страховка от бесконечного цикла
                if (out.size > 22050 * 1200) break // >20 минут — хватит
            }
        } catch (e: Exception) {
            // вернём то, что успели
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            codec.release()
            extractor.release()
        }
        if (out.isEmpty()) return null
        return Pcm(out.toShortArray(), sampleRate)
    }

    fun detect(
        pcm: ShortArray,
        rate: Int,
        sens: Double,
        minGapSec: Double,
        maxHits: Int,
    ): List<Beat> {
        var hop = 512 * rate / 22050
        if (hop < 64) hop = 64
        val frame = hop * 2
        if (pcm.size < frame) return emptyList()
        val nfr = (pcm.size - frame) / hop + 1

        val energy = DoubleArray(nfr)
        for (i in 0 until nfr) {
            var e = 0.0
            val off = i * hop
            var j = 0
            while (j < frame) {
                val s = pcm[off + j] / 32768.0
                e += s * s
                j += 4
            }
            energy[i] = e / (frame / 4)
        }
        val flux = DoubleArray(nfr)
        for (i in 1 until nfr) {
            val d = energy[i] - energy[i - 1]
            flux[i] = if (d > 0) d else 0.0
        }

        val sorted = flux.clone()
        sorted.sort()
        val p95 = sorted[(nfr * 0.95).toInt().coerceIn(0, nfr - 1)]
        if (p95 < 1e-9) return emptyList() // тишина

        var hist = (1.0 * rate / hop).toInt()
        if (hist < 8) hist = 8
        val k = 2.0 / sens
        var gapFr = (minGapSec * rate / hop).toInt()
        if (gapFr < 1) gapFr = 1

        val hits = ArrayList<Beat>()
        var lastHit = -gapFr * 2
        for (i in 1 until nfr - 1) {
            val w0 = max(0, i - hist)
            val win = flux.copyOfRange(w0, i).sorted()
            val med = if (win.size % 2 == 1) win[win.size / 2]
                      else 0.5 * (win[win.size / 2 - 1] + win[win.size / 2])
            var thr = med * k
            val floor = p95 * 0.02
            if (thr < floor) thr = floor
            if (energy[i] < 1e-7) continue
            if (flux[i] > thr && flux[i] >= flux[i - 1] && flux[i] >= flux[i + 1] &&
                i - lastHit >= gapFr) {
                var s = (flux[i] - thr) / (p95 - thr)
                s = s.coerceIn(0.0, 1.0)
                hits.add(Beat(i.toDouble() * hop / rate, s))
                lastHit = i
                if (maxHits > 0 && hits.size >= maxHits) break
            }
        }
        return hits
    }
}
