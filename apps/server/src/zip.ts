import { deflateRawSync } from "node:zlib";

export type ZipFile = { name: string; data: Uint8Array };

// A zip file holding these files, each deflated. Names are flagged as UTF-8
// (bit 11), so a realm or character with an accent keeps it. Every file is
// dated 1 January 1980, zip's earliest date: the journeys carry their own
// times. ponytail: no zip64, so the whole zip must stay under 4 GB.
export function zip(files: ZipFile[]): Uint8Array {
  const out: Uint8Array[] = [];
  const directory: Uint8Array[] = [];
  let offset = 0;
  for (const file of files) {
    const name = new TextEncoder().encode(file.name);
    const packed = deflateRawSync(file.data);
    const crc = Bun.hash.crc32(file.data);
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true);
    local.setUint16(8, 8, true);
    local.setUint16(12, 0x21, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, packed.length, true);
    local.setUint32(22, file.data.length, true);
    local.setUint16(26, name.length, true);
    const entry = new DataView(new ArrayBuffer(46));
    entry.setUint32(0, 0x02014b50, true);
    entry.setUint16(4, 20, true);
    entry.setUint16(6, 20, true);
    entry.setUint16(8, 0x0800, true);
    entry.setUint16(10, 8, true);
    entry.setUint16(14, 0x21, true);
    entry.setUint32(16, crc, true);
    entry.setUint32(20, packed.length, true);
    entry.setUint32(24, file.data.length, true);
    entry.setUint16(28, name.length, true);
    entry.setUint32(42, offset, true);
    out.push(new Uint8Array(local.buffer), name, packed);
    directory.push(new Uint8Array(entry.buffer), name);
    offset += 30 + name.length + packed.length;
  }
  const size = directory.reduce((n, part) => n + part.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, files.length, true);
  end.setUint16(10, files.length, true);
  end.setUint32(12, size, true);
  end.setUint32(16, offset, true);
  return new Uint8Array(Buffer.concat([...out, ...directory, new Uint8Array(end.buffer)]));
}
