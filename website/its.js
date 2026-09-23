// GeoNetworking / BTP / ITS PDU header extraction – JavaScript port of the iOS ItsFrameExtractor.

const SNAP_GN = [0xaa, 0xaa, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47];

export const MESSAGE_TYPES = {
  1: "DENM", 2: "CAM", 3: "POI", 4: "SPATEM", 5: "MAPEM", 6: "IVIM",
  9: "SREM", 10: "SSEM", 13: "RTCMEM", 14: "CPM", 15: "IMZM", 16: "VAM",
};
const PORT_TYPES = { 2001: "CAM", 2002: "DENM", 2003: "MAPEM", 2004: "SPATEM", 2006: "IVIM", 2007: "SREM", 2008: "SSEM", 2009: "CPM", 2018: "VAM" };

const u16 = (f, o) => (f[o] << 8) | f[o + 1];
const u32 = (f, o) => ((f[o] << 24) >>> 0) + (f[o + 1] << 16) + (f[o + 2] << 8) + f[o + 3];
const i32 = (f, o) => (f[o] << 24) | (f[o + 1] << 16) | (f[o + 2] << 8) | f[o + 3];

function indexOf(frame, pattern) {
  outer: for (let i = 0; i + pattern.length <= frame.length; i++) {
    for (let j = 0; j < pattern.length; j++) if (frame[i + j] !== pattern[j]) continue outer;
    return i;
  }
  return -1;
}

function parseCommon(f, common, secured) {
  if (f.length < common + 8) return null;
  if (((f[common] >> 4) & 0x0f) !== 2) return null; // BTP-B
  const headerType = f[common + 1] & 0xf0;
  let extLen, posOffset;
  if (headerType === 0x40) { extLen = 44; posOffset = 4; }       // GBC
  else if (headerType === 0x50) { extLen = 28; posOffset = 0; }  // SHB
  else return null;
  const payloadLength = u16(f, common + 4);
  if (payloadLength < 10) return null;
  const ext = common + 8, btp = ext + extLen;
  if (btp + payloadLength > f.length) return null;
  const its = btp + 4;
  const protocolVersion = f[its], messageId = f[its + 1];
  if (protocolVersion < 1 || protocolVersion > 3 || messageId === 0) return null;

  const lpv = ext + posOffset;
  let lat = null, lon = null;
  if (f.length >= lpv + 20) {
    lat = i32(f, lpv + 12) / 1e7;
    lon = i32(f, lpv + 16) / 1e7;
    if (Math.abs(lat) > 90 || Math.abs(lon) > 180 || (lat === 0 && lon === 0)) { lat = null; lon = null; }
  }
  const port = u16(f, btp);
  return {
    port, protocolVersion, messageId, secured,
    type: MESSAGE_TYPES[messageId] || PORT_TYPES[port] || `msg ${messageId}`,
    stationId: u32(f, its + 2),
    lat, lon,
  };
}

/** Returns {type, stationId, lat, lon, secured, port} or {error} for a raw 802.11 frame. */
export function extractIts(frame) {
  const snap = indexOf(frame, SNAP_GN);
  if (snap < 0) return { error: "kein GeoNetworking" };
  const basic = snap + SNAP_GN.length;
  if (frame.length < basic + 4) return { error: "GeoNetworking abgeschnitten" };
  const next = frame[basic] & 0x0f;
  if (next === 1) return parseCommon(frame, basic + 4, false) || { error: "GN-Header nicht unterstützt" };
  if (next === 2) {
    const start = basic + 4, end = Math.min(frame.length - 8 + 1, start + 512);
    let found = null;
    for (let off = start; off < end; off++) {
      const p = parseCommon(frame, off, true);
      if (!p) continue;
      if (found) return { error: "gesicherter Inhalt mehrdeutig", secured: true };
      found = p;
    }
    return found || { error: "gesicherter Inhalt ohne BTP-B", secured: true };
  }
  return { error: `GN next-header ${next}` };
}
