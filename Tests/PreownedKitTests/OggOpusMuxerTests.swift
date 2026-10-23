import Foundation
import Testing

@testable import PreownedKit

@Suite("Ogg Opus muxer")
struct OggOpusMuxerTests {
    /// A parsed Ogg page.
    struct Page {
        var flags: UInt8
        var granulePosition: Int64
        var serial: UInt32
        var sequenceNumber: UInt32
        var checksum: UInt32
        var lacing: [UInt8]
        var body: Data
        /// The page with its checksum field set to zero.
        var bytesWithoutChecksum: Data
    }

    static func pages(in data: Data) throws -> [Page] {
        var pages: [Page] = []
        var offset = data.startIndex
        func integer<T: FixedWidthInteger>(_: T.Type, at index: Int) -> T {
            data[index..<index + MemoryLayout<T>.size].reversed().reduce(T(0)) { $0 << 8 | T($1) }
        }
        while offset < data.endIndex {
            try #require(data[offset..<offset + 4] == Data("OggS".utf8))
            try #require(data[offset + 4] == 0)
            let segmentCount = Int(data[offset + 26])
            let lacing = Array(data[offset + 27..<offset + 27 + segmentCount])
            let bodyStart = offset + 27 + segmentCount
            let bodyEnd = bodyStart + lacing.reduce(0) { $0 + Int($1) }
            var bytes = Data(data[offset..<bodyEnd])
            bytes.replaceSubrange(22..<26, with: [0, 0, 0, 0])
            pages.append(
                Page(
                    flags: data[offset + 5],
                    granulePosition: integer(Int64.self, at: offset + 6),
                    serial: integer(UInt32.self, at: offset + 14),
                    sequenceNumber: integer(UInt32.self, at: offset + 18),
                    checksum: integer(UInt32.self, at: offset + 22),
                    lacing: lacing,
                    body: Data(data[bodyStart..<bodyEnd]),
                    bytesWithoutChecksum: bytes
                )
            )
            offset = bodyEnd
        }
        return pages
    }

    let muxer = OggOpusMuxer(serial: 0x1234_5678, preSkip: 312, inputSampleRate: 24_000)

    func packets(_ sizes: [Int]) -> [OggOpusMuxer.Packet] {
        sizes.enumerated().map { index, size in
            OggOpusMuxer.Packet(data: Data(repeating: UInt8(index & 0xFF), count: size), sampleCount: 960)
        }
    }

    @Test("The checksum matches the CRC-32 check value with Ogg's parameters")
    func checksum() {
        // CRC-32/CKSUM has the same polynomial, initial value, and reflection,
        // and its check value is 0x765E7680 after a final XOR with 0xFFFFFFFF.
        #expect(OggCRC.checksum(Data("123456789".utf8)) == 0x89A1_897F)
        #expect(OggCRC.checksum(Data()) == 0)
        #expect(OggCRC.table[1] == 0x04C1_1DB7)
    }

    @Test("The headers are on their own pages, with BOS, the pre-skip, and the vendor")
    func headers() throws {
        let pages = try Self.pages(in: muxer.file(packets: packets([100]), sampleCount: 960))
        try #require(pages.count == 3)

        let head = pages[0]
        #expect(head.flags == 0x02)
        #expect(head.granulePosition == 0)
        #expect(head.sequenceNumber == 0)
        #expect(head.lacing == [19])
        #expect(
            head.body
                == Data("OpusHead".utf8) + Data([1, 1, 0x38, 0x01, 0xC0, 0x5D, 0, 0, 0, 0, 0])
        )

        let tags = pages[1]
        #expect(tags.flags == 0)
        #expect(tags.granulePosition == 0)
        #expect(tags.sequenceNumber == 1)
        #expect(tags.body == Data("OpusTags".utf8) + Data([8, 0, 0, 0]) + Data("preowned".utf8) + Data([0, 0, 0, 0]))

        for (index, page) in pages.enumerated() {
            #expect(page.serial == 0x1234_5678)
            #expect(page.sequenceNumber == UInt32(index))
            #expect(page.checksum == OggCRC.checksum(page.bytesWithoutChecksum))
        }
    }

    @Test("Packets of 255 and 510 bytes end with a zero lacing value")
    func lacing() throws {
        let pages = try Self.pages(in: muxer.file(packets: packets([255, 510, 3]), sampleCount: 2880))
        try #require(pages.count == 3)
        #expect(pages[2].lacing == [255, 0, 255, 255, 0, 3])
        #expect(pages[2].body.count == 768)
        #expect(OggOpusMuxer.segmentCount(of: 254) == 1)
        #expect(OggOpusMuxer.segmentCount(of: 255) == 2)
        #expect(OggOpusMuxer.segmentCount(of: 510) == 3)
    }

    @Test("Each audio page has the granule position of its last packet, and the last page has EOS")
    func granulePositions() throws {
        var muxer = muxer
        muxer.maximumSegmentsPerPage = 4
        // Ten 20 ms packets of 100 bytes: four on a page.
        let file = muxer.file(packets: packets(Array(repeating: 100, count: 10)), sampleCount: 9_000)
        let pages = try Self.pages(in: file)
        try #require(pages.count == 5)
        let audio = pages.dropFirst(2)
        #expect(audio.map(\.lacing.count) == [4, 4, 2])
        #expect(audio.map(\.granulePosition) == [3_840, 7_680, 312 + 9_000])
        #expect(audio.map(\.flags) == [0, 0, 0x04])
        #expect(audio.map(\.sequenceNumber) == [2, 3, 4])
    }

    @Test("A packet too large for a page continues on the next page")
    func continuation() throws {
        var muxer = muxer
        muxer.maximumSegmentsPerPage = 2
        let pages = try Self.pages(in: muxer.file(packets: packets([600, 10]), sampleCount: 1_500))
        try #require(pages.count == 5)
        #expect(pages[2].lacing == [255, 255])
        #expect(pages[2].granulePosition == -1)
        #expect(pages[2].flags == 0)
        #expect(pages[3].lacing == [90])
        #expect(pages[3].granulePosition == 960)
        #expect(pages[3].flags == 0x01)
        #expect(pages[4].lacing == [10])
        #expect(pages[4].flags == 0x04)
        #expect(pages[4].granulePosition == 312 + 1_500)
    }

    @Test("A stream without packets still ends with an EOS page")
    func emptyStream() throws {
        let pages = try Self.pages(in: muxer.file(packets: [], sampleCount: 0))
        #expect(pages.map(\.flags) == [0x02, 0, 0x04])
        #expect(pages.last?.lacing == [])
    }
}
