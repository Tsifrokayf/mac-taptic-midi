package com.midihaptic.app.haptics

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Вибрация через системный Vibrator.
 * В отличие от мака, тут есть настоящая амплитуда 1..255.
 */
class HapticEngine(context: Context) {

    private val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= 31) {
        (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager)
            .defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
    }

    val hasVibrator: Boolean
        get() = try { vibrator.hasVibrator() } catch (_: Exception) { false }

    val amplitudeControl: Boolean =
        try { vibrator.hasAmplitudeControl() } catch (_: Exception) { false }

    /** Буст силы 1.0..3.0 (слайдер в UI). */
    var boost = 1f

    /**
     * Короткий удар, сила 0..1 (velocity/gain уже учтены снаружи).
     * Сильные удары — двойной импульс или EFFECT_HEAVY_CLICK: ощущается
     * в разы мощнее одиночного one-shot.
     */
    fun tap(strength01: Double) {
        val s = (strength01 * boost).coerceIn(0.0, 1.0)
        try {
            when {
                Build.VERSION.SDK_INT >= 29 && s >= 0.7 -> {
                    vibrator.vibrate(
                        VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
                    )
                }
                s >= 0.45 -> {
                    val amp = (60 + s * 195).toInt().coerceIn(1, 255)
                    vibrator.vibrate(
                        VibrationEffect.createWaveform(
                            longArrayOf(0, 30, 35, 55),
                            intArrayOf(0, 255, 0, amp), -1
                        )
                    )
                }
                else -> {
                    val amp = (60 + s * 195).toInt().coerceIn(1, 255)
                    val durMs = (25 + s * 45).toLong()
                    vibrator.vibrate(VibrationEffect.createOneShot(durMs, amp))
                }
            }
        } catch (_: Exception) {
        }
    }

    fun test() = tap(1.0)

    fun cancel() {
        try { vibrator.cancel() } catch (_: Exception) {
        }
    }
}
