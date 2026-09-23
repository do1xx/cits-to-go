// CAM / DENM decoding (EN 302 637-2 / -3, protocol versions 1 and 2) – port of the iOS CamDenmDecoder.
// Input: the ITS PDU bytes starting at the 6-byte ItsPduHeader.

class Bits {
  constructor(bytes, byteOffset) { this.b = bytes; this.p = byteOffset * 8; }
  n(width) {
    if (this.p + width > this.b.length * 8) throw new Error("PER payload ended early");
    let v = 0;
    for (let i = 0; i < width; i++) {
      v = v * 2 + ((this.b[this.p >> 3] >> (7 - (this.p & 7))) & 1);
      this.p++;
    }
    return v;
  }
  bit() { return this.n(1) === 1; }
  int(lo, hi) { const range = hi - lo + 1; return lo + this.n(range <= 1 ? 0 : Math.ceil(Math.log2(range))); }
  length() {
    if (!this.bit()) return this.n(7);
    if (!this.bit()) return this.n(14);
    throw new Error("fragmented length");
  }
  skipOpenType() { this.p += this.length() * 8; }
  normallySmall() { return this.bit() ? this.length() : this.n(6); }
  skipExtensions() {
    const count = this.bit() ? this.length() : this.n(6) + 1;
    let present = 0;
    for (let i = 0; i < count; i++) if (this.bit()) present++;
    for (let i = 0; i < present; i++) this.skipOpenType();
  }
  choice(rootCount, extensible) {
    if (extensible && this.bit()) { this.normallySmall(); this.skipOpenType(); return null; }
    return this.n(rootCount <= 1 ? 0 : Math.ceil(Math.log2(rootCount)));
  }
}

export const STATION_TYPES = {
  0: "Unbekannt", 1: "Fußgänger", 2: "Radfahrer", 3: "Moped", 4: "Motorrad", 5: "Pkw", 6: "Bus",
  7: "Leichter Lkw", 8: "Schwerer Lkw", 9: "Anhänger", 10: "Sonderfahrzeug", 11: "Straßenbahn", 15: "Straßenstation",
};
const ROLES = ["Standard", "ÖPNV", "Sondertransport", "Gefahrgut", "Straßenbau", "Rettung/Bergung", "Einsatzfahrzeug",
  "Sicherungsfahrzeug", "Landwirtschaft", "Gewerblich", "Militär", "Straßenbetreiber", "Taxi"];
const CAUSES = {
  1: "Verkehrsstörung", 2: "Unfall", 3: "Baustelle", 6: "Glätte", 9: "Gefährlicher Straßenzustand",
  10: "Hindernis auf der Fahrbahn", 11: "Tier auf der Fahrbahn", 12: "Personen auf der Fahrbahn", 14: "Falschfahrer",
  15: "Rettungs- und Bergungsarbeiten", 17: "Extremwetter", 18: "Sichtbehinderung", 19: "Niederschlag",
  26: "Langsames Fahrzeug", 27: "Stauende", 91: "Panne", 92: "Unfallfahrzeug", 93: "Notfall im Fahrzeug",
  94: "Liegengebliebenes Fahrzeug", 95: "Einsatzfahrzeug nähert sich", 96: "Gefährliche Kurve",
  97: "Kollisionsgefahr", 98: "Rotlichtverstoß", 99: "Gefahrensituation",
};
const SUB_CAUSES = {
  1: { 1: "erhöhtes Verkehrsaufkommen", 2: "Stau wächst langsam", 3: "Stau wächst", 4: "Stau wächst stark", 5: "stehender Verkehr", 6: "Stau nimmt leicht ab", 7: "Stau nimmt ab", 8: "Stau nimmt stark ab" },
  3: { 1: "große Baustelle", 2: "Markierungsarbeiten", 3: "Wanderbaustelle", 4: "Tagesbaustelle", 5: "Straßenreinigung", 6: "Winterdienst" },
  27: { 1: "plötzliches Stauende", 2: "Stau hinter Kuppe", 3: "Stau hinter Kurve", 4: "Stau im Tunnel" },
  91: { 1: "Kraftstoffmangel", 2: "leere Batterie", 3: "Motorproblem", 4: "Getriebeproblem", 5: "Motorkühlung", 6: "Bremsen", 7: "Lenkung", 8: "Reifenpanne" },
  94: { 1: "Notfall im Fahrzeug", 2: "Panne", 3: "Unfallfahrzeug", 4: "Haltestelle", 5: "Gefahrgut" },
  95: { 1: "Einsatzfahrzeug", 2: "bevorrechtigtes Fahrzeug" },
};

function referencePosition(r) {
  const lat = r.int(-900000000, 900000001), lon = r.int(-1800000000, 1800000001);
  r.n(12); r.n(12); r.n(12); r.n(20); r.n(4);
  return lat === 900000001 || lon === 1800000001 ? { lat: null, lon: null } : { lat: lat / 1e7, lon: lon / 1e7 };
}

export function decodeCam(pdu) {
  const r = new Bits(pdu, 6);
  r.n(16);
  r.bit(); const hasLow = r.bit(), hasSpecial = r.bit();
  const basicExt = r.bit();
  const cam = { stationType: r.n(8), speedKmh: null, heading: null, role: null, lightBar: false, siren: false };
  Object.assign(cam, referencePosition(r));
  if (basicExt) r.skipExtensions();
  const hf = r.choice(2, true);
  if (hf === 0) {
    const opt = Array.from({ length: 7 }, () => r.bit());
    const heading = r.int(0, 3601); r.n(7);
    if (heading < 3601) cam.heading = heading / 10;
    const speed = r.int(0, 16383); r.n(7);
    if (speed < 16383) cam.speedKmh = speed / 100 * 3.6;
    r.n(2); r.n(10); r.n(3); r.n(6); r.n(9); r.n(7); r.n(11); r.n(3);
    if (r.bit()) r.normallySmall(); else r.n(2);   // curvatureCalculationMode (extensible enum)
    r.n(16); r.n(4);                               // yawRate
    if (opt[0]) r.n(7);
    if (opt[1]) r.n(4);
    if (opt[2]) { r.n(10); r.n(7); }
    if (opt[3]) { r.n(9); r.n(7); }
    if (opt[4]) { r.n(9); r.n(7); }
    if (opt[5]) r.n(3);
    if (opt[6]) { const ext = r.bit(), id = r.bit(); r.n(31); r.n(32); if (id) r.n(27); if (ext) r.skipExtensions(); }
  } else {
    return cam;
  }
  if (hasLow) {
    if (r.choice(1, true) === null) return cam;
    cam.role = r.n(4);
    r.n(8);
    const points = r.int(0, 40);
    for (let i = 0; i < points; i++) { const t = r.bit(); r.n(18); r.n(18); r.n(15); if (t) r.n(16); }
  }
  if (hasSpecial) {
    const kind = r.choice(7, true);
    let light = null;
    if (kind === 3) { const sub = r.bit(); r.bit(); if (sub) r.n(8); light = r.n(2); }
    else if (kind === 4) light = r.n(2);
    else if (kind === 5) { r.n(2); light = r.n(2); }
    else if (kind === 6) { r.n(3); light = r.n(2); }
    if (light !== null) { cam.lightBar = (light & 2) !== 0; cam.siren = (light & 1) !== 0; }
  }
  return cam;
}

export function camSummary(c) {
  const parts = [c.role && c.role > 0 ? ROLES[c.role] || "Sonderrolle" : STATION_TYPES[c.stationType] || `Typ ${c.stationType}`];
  if (c.speedKmh != null) parts.push(`${Math.round(c.speedKmh)} km/h`);
  if (c.lightBar || c.siren) parts.push(c.siren ? "Blaulicht + Horn" : "Blaulicht");
  return parts.join(", ");
}

export function decodeDenm(pdu) {
  const r = new Bits(pdu, 6);
  const hasSituation = r.bit(); r.bit(); r.bit();
  const mgmtExt = r.bit();
  const hasTerm = r.bit(), hasDist = r.bit(), hasDir = r.bit(), hasValidity = r.bit(), hasInterval = r.bit();
  const originatingStationId = r.n(32), sequenceNumber = r.n(16);
  const detection = r.n(42), reference = r.n(42);
  if (hasTerm) r.n(1);
  const pos = referencePosition(r);
  if (hasDist) r.n(3);
  if (hasDir) r.n(2);
  const validity = hasValidity ? r.int(0, 86400) : 600;
  if (hasInterval) r.n(14);
  const stationType = r.n(8);
  if (mgmtExt) r.skipExtensions();
  const epoch = Date.UTC(2004, 0, 1) - 5000;   // TAI → UTC: 5 leap seconds since 2004
  const denm = {
    originatingStationId, sequenceNumber, terminated: hasTerm, stationType, validity, ...pos,
    detectionTime: new Date(epoch + detection), referenceTime: new Date(epoch + reference),
    cause: null, subCause: null,
  };
  if (hasSituation) { r.n(3); r.n(3); r.bit(); denm.cause = r.n(8); denm.subCause = r.n(8); }
  return denm;
}

export function denmSummary(d) {
  let s = CAUSES[d.cause] || (d.cause == null ? "Warnung" : `Warnung (Code ${d.cause})`);
  const sub = SUB_CAUSES[d.cause]?.[d.subCause];
  if (sub) s += ` – ${sub}`;
  return d.terminated ? `Aufgehoben: ${s}` : s;
}
