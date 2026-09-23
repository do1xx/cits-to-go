// Arms the CITS-to-go firmware's one-shot BLE enrollment window over Web Serial.
// Same CTG1 record as ios-app/tools/arm_enrollment.py and the Android app.

const TYPE_BLE_ENROLL_REQUEST = 4;
const TYPE_BLE_ENROLL_RESULT = 5;
const ESPRESSIF_USB_VENDOR = 0x303a;

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

export function crc32(bytes) {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function cobsEncode(input) {
  const out = [0];
  let codeIndex = 0, code = 1;
  for (const b of input) {
    if (b === 0) {
      out[codeIndex] = code; codeIndex = out.length; out.push(0); code = 1;
    } else {
      out.push(b); code++;
      if (code === 0xff) { out[codeIndex] = code; codeIndex = out.length; out.push(0); code = 1; }
    }
  }
  out[codeIndex] = code;
  return Uint8Array.from(out);
}

export function cobsDecode(input) {
  const out = [];
  let i = 0;
  while (i < input.length) {
    const code = input[i++];
    if (code === 0 || i + code - 1 > input.length) throw new Error("malformed COBS");
    for (let j = 1; j < code; j++) out.push(input[i++]);
    if (code < 0xff && i < input.length) out.push(0);
  }
  return Uint8Array.from(out);
}

export function enrollmentRequest() {
  const body = new Uint8Array(16);
  body.set([0x43, 0x54, 0x47, 0x31, 1, TYPE_BLE_ENROLL_REQUEST, 12, 0]); // "CTG1", v1, type, header len
  body[8] = 1; // replace existing owner, arm exactly one pairing attempt
  new DataView(body.buffer).setUint32(12, crc32(body.subarray(0, 12)), true);
  const enc = cobsEncode(body);
  const framed = new Uint8Array(enc.length + 1);
  framed.set(enc);
  return framed; // trailing 0x00 delimiter
}

/** Returns {status, armed} if `record` (decoded) is an enrollment result, else null. */
export function parseEnrollmentResult(record) {
  if (record.length < 20) return null;
  if (record[0] !== 0x43 || record[1] !== 0x54 || record[2] !== 0x47 || record[3] !== 0x31) return null;
  if (record[5] !== TYPE_BLE_ENROLL_RESULT) return null;
  const dv = new DataView(record.buffer, record.byteOffset, record.byteLength);
  if (crc32(record.subarray(0, record.length - 4)) !== dv.getUint32(record.length - 4, true)) return null;
  return { status: dv.getUint32(8, true), armed: record[12] !== 0 };
}

export class EnrollError extends Error {
  constructor(kind, message) { super(message); this.kind = kind; }
}

/** Opens the port chosen by the user, sends the request and waits up to 3 s for the ack. */
export async function armEnrollment() {
  if (!("serial" in navigator)) throw new EnrollError("unsupported", "Web Serial not available");
  let port;
  try {
    port = await navigator.serial.requestPort({ filters: [{ usbVendorId: ESPRESSIF_USB_VENDOR }] });
  } catch {
    throw new EnrollError("cancelled", "No port selected");
  }
  try {
    await port.open({ baudRate: 115200 });
  } catch {
    throw new EnrollError("busy", "Port could not be opened");
  }
  const reader = port.readable.getReader();
  try {
    const writer = port.writable.getWriter();
    await writer.write(enrollmentRequest());
    writer.releaseLock();

    const deadline = Date.now() + 3000;
    let record = [];
    while (Date.now() < deadline) {
      const timeout = new Promise((r) => setTimeout(() => r({ timeout: true }), deadline - Date.now()));
      const res = await Promise.race([reader.read(), timeout]);
      if (res.timeout || res.done) break;
      for (const b of res.value) {
        if (b !== 0) { if (record.length < 8192) record.push(b); continue; }
        if (record.length) {
          let result = null;
          try { result = parseEnrollmentResult(cobsDecode(Uint8Array.from(record))); } catch {}
          if (result) {
            if (result.status === 0 && result.armed) return result;
            throw new EnrollError("refused", `Firmware refused (status ${result.status})`);
          }
        }
        record = [];
      }
    }
    throw new EnrollError("noreply", "No acknowledgement");
  } finally {
    try { await reader.cancel(); } catch {}
    reader.releaseLock();
    try { await port.close(); } catch {}
  }
}
