import Foundation

/// Writes Opus packets in an Ogg container,
/// as RFC 7845 (Ogg Opus) and RFC 3533 (Ogg) describe.
///
/// The muxer writes mono streams with channel mapping family 0.
/// The first page holds the `OpusHead` packet and has the beginning-of-stream flag;
/// the second page holds the `OpusTags` packet;
/// the audio pages follow, and the last one has the end-of-stream flag.
struct OggOpusMuxer {
    /// The stream's serial number, the same on every page.
    var serial: UInt32
    /// The samples at 48 kHz that a decoder discards from the start of the stream.
    var preSkip: UInt16
    /// The sample rate of the original audio, for information only.
    var inputSampleRate: UInt32
    /// The vendor string in the `OpusTags` packet.
    var vendor = "preowned"
    /// The most segments that the muxer puts in one audio page.
    /// RFC 3533 allows 255.
    var maximumSegmentsPerPage = 255

    /// One Opus packet and its duration.
    struct Packet {
        var data: Data
        /// The packet's samples at 48 kHz, such as 960 for 20 ms.
        var sampleCount: Int
    }

    /// The `OpusHead` identification header.
    var header: Data {
        var data = Data("OpusHead".utf8)
        data.append(1)  // The version.
        data.append(1)  // The channel count.
        data.appendLittleEndian(preSkip)
        data.appendLittleEndian(inputSampleRate)
        data.appendLittleEndian(Int16(0))  // The output gain.
        data.append(0)  // Channel mapping family 0: mono or stereo.
        return data
    }

    /// The `OpusTags` comment header, with the vendor string and no comments.
    var tags: Data {
        var data = Data("OpusTags".utf8)
        let vendor = Data(vendor.utf8)
        data.appendLittleEndian(UInt32(vendor.count))
        data.append(vendor)
        data.appendLittleEndian(UInt32(0))  // The comment count.
        return data
    }

    /// An Ogg Opus file.
    ///
    /// - Parameters:
    ///   - packets: The Opus packets, in order.
    ///   - sampleCount: The samples of real audio at 48 kHz, without the pre-skip.
    ///     The last page's granule position is `preSkip + sampleCount`,
    ///     so a decoder trims the encoder's padding at the end.
    func file(packets: [Packet], sampleCount: Int) -> Data {
        var pageWriter = PageWriter(serial: serial)
        pageWriter.write([header], granulePosition: 0, flags: .beginningOfStream)
        pageWriter.write([tags], granulePosition: 0)

        let endPosition = Int64(preSkip) + Int64(sampleCount)
        var position: Int64 = 0
        var index = 0
        while index < packets.count {
            // Fill a page with whole packets, up to the segment limit.
            // A packet that needs more segments than a page holds
            // continues on the next pages.
            var segments = 0
            var pagePackets: [Data] = []
            while index < packets.count {
                let needed = Self.segmentCount(of: packets[index].data.count)
                if !pagePackets.isEmpty, segments + needed > maximumSegmentsPerPage {
                    break
                }
                pagePackets.append(packets[index].data)
                position += Int64(packets[index].sampleCount)
                segments += needed
                index += 1
            }
            let isLast = index == packets.count
            pageWriter.write(
                pagePackets,
                granulePosition: isLast ? min(position, endPosition) : position,
                flags: isLast ? .endOfStream : [],
                maximumSegments: maximumSegmentsPerPage
            )
        }
        if packets.isEmpty {
            // A stream needs an end-of-stream page even without audio.
            pageWriter.write([], granulePosition: 0, flags: .endOfStream)
        }
        return pageWriter.data
    }

    /// The lacing values that a packet needs:
    /// one for every 255 bytes, and one more, which is less than 255.
    static func segmentCount(of size: Int) -> Int {
        size / 255 + 1
    }
}

// MARK: - Pages

/// Writes Ogg pages for one logical stream.
struct PageWriter {
    struct Flags: OptionSet {
        let rawValue: UInt8
        /// The page continues a packet from the previous page.
        static let continued = Flags(rawValue: 0x01)
        static let beginningOfStream = Flags(rawValue: 0x02)
        static let endOfStream = Flags(rawValue: 0x04)
    }

    let serial: UInt32
    private(set) var data = Data()
    private(set) var sequenceNumber: UInt32 = 0

    init(serial: UInt32) {
        self.serial = serial
    }

    /// Writes packets on one page,
    /// or one packet that is too large for a page on several pages.
    ///
    /// RFC 3533 gives a page the granule position of the last packet that ends on it,
    /// and -1 if no packet ends on it,
    /// so only the last page of a long packet has `granulePosition`.
    mutating func write(
        _ packets: [Data],
        granulePosition: Int64,
        flags: Flags = [],
        maximumSegments: Int = 255
    ) {
        // Each element is a lacing value and whether a packet ends with it.
        var lacing: [(value: UInt8, endsPacket: Bool)] = []
        var body = Data()
        precondition(
            packets.count <= 1 || packets.reduce(0) { $0 + OggOpusMuxer.segmentCount(of: $1.count) } <= maximumSegments,
            "Only one packet can span pages."
        )
        for packet in packets {
            var remaining = packet.count
            while remaining >= 255 {
                lacing.append((255, false))
                remaining -= 255
            }
            lacing.append((UInt8(remaining), true))
            body.append(packet)
        }

        var segmentStart = 0
        var byteStart = 0
        var continued = false
        repeat {
            let segmentEnd = min(segmentStart + maximumSegments, lacing.count)
            let pageLacing = lacing[segmentStart..<segmentEnd]
            let byteCount = pageLacing.reduce(0) { $0 + Int($1.value) }
            let isLast = segmentEnd == lacing.count
            var pageFlags: Flags = segmentStart == 0 ? flags.intersection(.beginningOfStream) : []
            if continued { pageFlags.insert(.continued) }
            if isLast { pageFlags.formUnion(flags.intersection(.endOfStream)) }
            let position = isLast ? granulePosition : -1
            appendPage(
                lacing: pageLacing.map(\.value),
                body: body[body.startIndex + byteStart..<body.startIndex + byteStart + byteCount],
                granulePosition: position,
                flags: pageFlags
            )
            continued = pageLacing.last.map { !$0.endsPacket } ?? false
            segmentStart = segmentEnd
            byteStart += byteCount
        } while segmentStart < lacing.count
    }

    private mutating func appendPage(
        lacing: [UInt8],
        body: Data,
        granulePosition: Int64,
        flags: Flags
    ) {
        var page = Data("OggS".utf8)
        page.append(0)  // The stream structure version.
        page.append(flags.rawValue)
        page.appendLittleEndian(granulePosition)
        page.appendLittleEndian(serial)
        page.appendLittleEndian(sequenceNumber)
        let checksumOffset = page.count
        page.appendLittleEndian(UInt32(0))  // The checksum, computed below.
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        page.append(body)
        let checksum = OggCRC.checksum(page)
        withUnsafeBytes(of: checksum.littleEndian) { bytes in
            page.replaceSubrange(checksumOffset..<checksumOffset + 4, with: bytes)
        }
        data.append(page)
        sequenceNumber += 1
    }
}

// MARK: - Checksum

/// The Ogg page checksum:
/// CRC-32 with the polynomial 0x04C11DB7, no reflection,
/// an initial value of 0, and no final XOR.
enum OggCRC {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(UInt8(crc >> 24) ^ byte)]
        }
        return crc
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
