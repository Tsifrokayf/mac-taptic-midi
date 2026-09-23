package com.midihaptic.app.audio

/** Нота с абсолютным временем в секундах. */
data class MidiNote(
    val timeSec: Double,
    val midi: Int,
    val vel: Int,
    val ch: Int,
)

data class MidiSong(
    val notes: List<MidiNote>,
    val durationSec: Double,
    val ntracks: Int,
    val format: Int,
)

/**
 * Парсер Standard MIDI File (формат 0/1), порт midi_haptic.c.
 * Без зависимостей: note_on + карта темпа, остальное пропускается.
 */
object MidiParser {

    private class Reader(val b: ByteArray) {
        var pos = 0
        fun u8(): Int = b[pos++].toInt() and 0xFF
        fun u16be(): Int = (u8() shl 8) or u8()
        fun u32be(): Long = (u8().toLong() shl 24) or (u8().toLong() shl 16) or
                (u8().toLong() shl 8) or u8().toLong()

        /** Variable Length Quantity, -1 при обрыве. */
        fun vlq(): Long {
            var v = 0L
            repeat(4) {
                if (pos >= b.size) return -1
                val c = u8()
                v = (v shl 7) or (c and 0x7F).toLong()
                if (c and 0x80 == 0) return v
            }
            return -1
        }
    }

    private data class RawNote(val tick: Long, val note: Int, val vel: Int, val ch: Int, val track: Int)
    private data class RawTempo(val tick: Long, val usPerQuarter: Long)

    fun parse(bytes: ByteArray): MidiSong {
        val r = Reader(bytes)
        require(bytes.size >= 14 && bytes[0] == 'M'.code.toByte() &&
                bytes[1] == 'T'.code.toByte() && bytes[2] == 'h'.code.toByte() &&
                bytes[3] == 'd'.code.toByte()) { "не MThd — это не Standard MIDI File" }
        r.pos = 4
        val hlen = r.u32be()
        require(hlen >= 6) { "битый MThd" }
        val format = r.u16be()
        val ntracks = r.u16be()
        val division = r.u16be()
        require(division and 0x8000 == 0 && division != 0) { "SMPTE-тайминг не поддерживается" }
        r.pos = (8 + hlen).toInt()

        val notes = ArrayList<RawNote>()
        val tempos = ArrayList<RawTempo>()
        repeat(ntracks) { t ->
            if (r.pos + 8 > bytes.size) return@repeat
            val tag = String(bytes, r.pos, 4, Charsets.US_ASCII)
            val len = r.u32beAt(r.pos + 4)
            r.pos += 8
            if (tag != "MTrk") {
                r.pos = (r.pos + len).toInt().coerceAtMost(bytes.size)
                return@repeat
            }
            val end = (r.pos + len).toInt().coerceAtMost(bytes.size)
            parseTrack(r, end, t, notes, tempos)
            r.pos = end
        }
        require(notes.isNotEmpty()) { "note_on событий не найдено" }
        notes.sortWith(compareBy({ it.tick }, { it.track }))
        tempos.sortBy { it.tick }

        // тики -> секунды по карте темпа
        var usPerTick = 500000.0 / division
        for (tp in tempos) if (tp.tick == 0L) usPerTick = tp.usPerQuarter / division.toDouble()
        var ti = tempos.indexOfFirst { it.tick != 0L }
        if (ti < 0) ti = tempos.size
        var lastTick = 0L
        var lastSec = 0.0
        val out = ArrayList<MidiNote>(notes.size)
        for (n in notes) {
            while (ti < tempos.size && tempos[ti].tick <= n.tick) {
                val tt = tempos[ti]
                lastSec += (tt.tick - lastTick) * usPerTick / 1e6
                lastTick = tt.tick
                usPerTick = tt.usPerQuarter / division.toDouble()
                ti++
            }
            out.add(MidiNote(lastSec + (n.tick - lastTick) * usPerTick / 1e6, n.note, n.vel, n.ch))
        }
        return MidiSong(out, out.last().timeSec, ntracks, format)
    }

    private fun Reader.u32beAt(p: Int): Long {
        val save = pos
        pos = p
        val v = u32be()
        pos = save
        return v
    }

    private fun parseTrack(
        r: Reader, end: Int, track: Int,
        notes: MutableList<RawNote>, tempos: MutableList<RawTempo>,
    ) {
        var absTick = 0L
        var running = 0
        while (r.pos < end) {
            val delta = r.vlq()
            if (delta < 0) return
            absTick += delta
            if (r.pos >= end) break
            val peek = r.b[r.pos].toInt() and 0xFF
            val status: Int
            if (peek and 0x80 != 0) {
                status = r.u8()
            } else {
                if (running == 0) return
                status = running
            }
            when (status) {
                0xFF -> {
                    if (r.pos + 1 > end) return
                    val type = r.u8()
                    val mlen = r.vlq()
                    if (mlen < 0 || r.pos + mlen > end) return
                    if (type == 0x51 && mlen == 3L) {
                        var usq = 0L
                        repeat(3) { usq = (usq shl 8) or r.u8().toLong() }
                        if (usq == 0L) usq = 500000
                        tempos.add(RawTempo(absTick, usq))
                    } else if (type == 0x2F) {
                        return
                    } else {
                        r.pos = (r.pos + mlen).toInt()
                    }
                }
                0xF0, 0xF7 -> {
                    val slen = r.vlq()
                    if (slen < 0 || r.pos + slen > end) return
                    r.pos = (r.pos + slen).toInt()
                    running = 0
                }
                else -> {
                    running = status
                    val hi = status and 0xF0
                    val ch = status and 0x0F
                    if (hi == 0xC0 || hi == 0xD0) {
                        if (r.pos + 1 > end) return
                        r.pos += 1
                    } else {
                        if (r.pos + 2 > end) return
                        val d0 = r.u8()
                        val d1 = r.u8()
                        if (hi == 0x90 && d1 != 0) {
                            notes.add(RawNote(absTick, d0, d1, ch, track))
                        }
                    }
                }
            }
        }
    }
}
