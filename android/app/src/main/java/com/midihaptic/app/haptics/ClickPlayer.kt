package com.midihaptic.app.haptics

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.ToneGenerator
import android.util.Log
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin

/**
 * Стук метронома: короткий «ток» деревянного блока, а не пищалка.
 * Синтез на лету (синус 1760/1320 Гц + щелчок атаки, 30 мс, резкий спад),
 * игра через AudioTrack. Если AudioTrack не завёлся — фолбэк на ToneGenerator.
 */
class ClickPlayer(private val audio: AudioManager) {

    private var track: AudioTrack? = null
    private var tone: ToneGenerator? = null
    private var audioOk: Boolean? = null // null = ещё не проверяли

    /** Синтез тока: freq Гц, длительность 30 мс. */
    private fun synth(freqHz: Int): ShortArray {
        val sr = 44100
        val n = sr * 30 / 1000
        val out = ShortArray(n)
        // лёгкий шум атаки первые 2 мс для «деревянности»
        var seed = 0x12345678L
        fun noise(): Double {
            seed = seed * 1103515245L + 12345L
            return ((seed ushr 16) and 0x7FFF).toDouble() / 0x7FFF - 0.5
        }
        for (i in 0 until n) {
            val t = i.toDouble() / sr
            val body = sin(2 * PI * freqHz * t) * exp(-t / 0.006)
            val attack = if (i < sr * 2 / 1000) noise() * exp(-t / 0.001) * 0.6 else 0.0
            out[i] = ((body + attack) * 26000).toInt()
                .coerceIn(-32768, 32767).toShort()
        }
        return out
    }

    @Synchronized
    fun play(accent: Boolean = false) {
        if (audioOk == false) {
            fallback(accent)
            return
        }
        try {
            val sr = 44100
            var t = track
            if (t == null || t.state != AudioTrack.STATE_INITIALIZED) {
                try { t?.release() } catch (_: Exception) {
                }
                t = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sr)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(sr * 30 / 1000 * 2)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                track = t
            }
            if (t.state != AudioTrack.STATE_INITIALIZED) {
                Log.w("HapticMidi", "click: track not initialized, fallback")
                audioOk = false
                fallback(accent)
                return
            }
            val buf = synth(if (accent) 1760 else 1320)
            t.stop()
            t.flush()
            val wrote = t.write(buf, 0, buf.size)
            t.play()
            if (audioOk == null) {
                audioOk = wrote > 0 &&
                        t.playState == AudioTrack.PLAYSTATE_PLAYING
                Log.i("HapticMidi",
                    "click: write=$wrote playState=${t.playState} ok=$audioOk")
            }
        } catch (e: Exception) {
            Log.w("HapticMidi", "click:AudioTrack failed (${e.message}), fallback")
            audioOk = false
            fallback(accent)
        }
    }

    private fun fallback(accent: Boolean) {
        try {
            var t = tone
            if (t == null) {
                t = ToneGenerator(AudioManager.STREAM_MUSIC, 100)
                tone = t
            }
            t.startTone(
                if (accent) ToneGenerator.TONE_CDMA_PIP else ToneGenerator.TONE_PROP_BEEP,
                70
            )
        } catch (_: Exception) {
        }
    }

    /** «громкость медиа» для диагностики: если 0 — клика не слышно. */
    fun musicVolume(): String = try {
        "${audio.getStreamVolume(AudioManager.STREAM_MUSIC)}/" +
                "${audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)}"
    } catch (_: Exception) {
        "?"
    }

    fun release() {
        try { track?.release() } catch (_: Exception) {
        }
        track = null
        try { tone?.release() } catch (_: Exception) {
        }
        tone = null
    }
}
