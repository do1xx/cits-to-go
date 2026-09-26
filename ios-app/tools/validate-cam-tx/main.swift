import Foundation
import CoreLocation
// Generates CAM frames, writes them to a PCAP for tshark and round-trips them through our decoder.
var pcap: [UInt8] = []
func le32(_ v: UInt32) { for i in 0..<4 { pcap.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
le32(0xA1B2C3D4); pcap += [2, 0, 4, 0]; le32(0); le32(0); le32(65535); le32(105)
let id = CamIdentity.random()
let now = Date()
let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 53.5696, longitude: 9.9624), altitude: 12.3,
                     horizontalAccuracy: 3.2, verticalAccuracy: 4, course: 271.4, courseAccuracy: 2.5,
                     speed: 13.9, speedAccuracy: 0.4, timestamp: now)
let cases: [(StationType, CamPosition)] = [(.passengerCar, CamPosition(location: loc)), (.cyclist, CamPosition(location: loc)),
    (.heavyTruck, CamPosition(location: loc)), (.pedestrian, CamPosition()), (.roadSideUnit, CamPosition(location: loc))]
for (type, pos) in cases {
    let f = CamEncoder.camFrame(identity: id, stationType: type, position: pos, now: now)
    le32(UInt32(now.timeIntervalSince1970)); le32(0); le32(UInt32(f.count)); le32(UInt32(f.count)); pcap += f
    guard case .success(let its) = ItsFrameExtractor.extract(f) else { print("EXTRACT-FAIL", type); continue }
    let c = try! CamDenmDecoder.decodeCam(its)
    print("roundtrip \(type.label): station=\(its.stationId == id.stationId) type=\(c.stationType == type) lat=\(c.latitude.map { String(format: "%.7f", $0) } ?? "-") speed=\(c.speedKmh.map { String(format: "%.2f", $0) } ?? "-") heading=\(c.headingDegrees.map { String(format: "%.1f", $0) } ?? "-") mac=\(Ieee80211Mac.sourceAddress(f) == id.macString)")
}
try! Data(pcap).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("stationId", id.stationId, "mac", id.macString)
