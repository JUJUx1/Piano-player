// ╔══════════════════════════════════════════════════════════╗
// ║  Auto Piano Sync Server v2                               ║
// ║  Dependencies: express, socket.io, @octokit/rest,       ║
// ║                cors, dotenv, multer                      ║
// ║  MIDI parsing: built-in (no external midi package)       ║
// ╚══════════════════════════════════════════════════════════╝

require("dotenv").config();
const express     = require("express");
const http        = require("http");
const { Server }  = require("socket.io");
const cors        = require("cors");
const multer      = require("multer");
const path        = require("path");
const { Octokit } = require("@octokit/rest");

const app    = express();
const server = http.createServer(app);
const io     = new Server(server, {
  cors: { origin: "*", methods: ["GET", "POST"] }
});

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 }
});

// ── GitHub config ─────────────────────────────────────────
const GITHUB_TOKEN  = process.env.GITHUB_TOKEN;
const GITHUB_OWNER  = process.env.GITHUB_OWNER;
const GITHUB_REPO   = process.env.GITHUB_REPO   || "piano-songs";
const GITHUB_BRANCH = process.env.GITHUB_BRANCH || "main";

const octokit = new Octokit({ auth: GITHUB_TOKEN });

// ─────────────────────────────────────────────────────────
//  BUILT-IN MIDI PARSER (no external package needed)
// ─────────────────────────────────────────────────────────

class MidiReader {
  constructor(buffer) {
    this.buf = buffer instanceof Buffer ? buffer : Buffer.from(buffer);
    this.pos = 0;
  }
  readUint8()  { return this.buf.readUInt8(this.pos++); }
  readUint16() { const v = this.buf.readUInt16BE(this.pos); this.pos+=2; return v; }
  readUint32() { const v = this.buf.readUInt32BE(this.pos); this.pos+=4; return v; }
  readBytes(n) { const s = this.buf.slice(this.pos, this.pos+n); this.pos+=n; return s; }
  readVarLen() {
    let val=0, b;
    do { b=this.readUint8(); val=(val<<7)|(b&0x7f); } while (b&0x80);
    return val;
  }
  readString(n) { return this.readBytes(n).toString("ascii"); }
}

function parseMidi(buffer) {
  const r = new MidiReader(buffer);

  // Header chunk
  const headerTag = r.readString(4);
  if (headerTag !== "MThd") throw new Error("Not a valid MIDI file (bad header)");
  r.readUint32(); // header length (always 6)
  const format        = r.readUint16();
  const trackCount    = r.readUint16();
  const timeDivision  = r.readUint16();

  const tracks = [];

  for (let t = 0; t < trackCount; t++) {
    const trackTag = r.readString(4);
    if (trackTag !== "MTrk") throw new Error(`Bad track header at track ${t}`);
    const trackLen = r.readUint32();
    const trackEnd = r.pos + trackLen;

    const events = [];
    let lastStatus = 0;

    while (r.pos < trackEnd) {
      const deltaTime = r.readVarLen();
      let statusByte  = r.buf.readUInt8(r.pos);

      // Running status
      if (statusByte & 0x80) {
        lastStatus = statusByte;
        r.pos++;
      } else {
        statusByte = lastStatus;
      }

      const type    = (statusByte >> 4) & 0xF;
      const channel = statusByte & 0xF;

      if (statusByte === 0xFF) {
        // Meta event
        const metaType = r.readUint8();
        const metaLen  = r.readVarLen();
        const metaData = r.readBytes(metaLen);
        if (metaType === 0x51 && metaLen === 3) {
          // Tempo
          const tempo = (metaData[0] << 16) | (metaData[1] << 8) | metaData[2];
          events.push({ deltaTime, type: "tempo", tempo });
        } else if (metaType === 0x2F) {
          events.push({ deltaTime, type: "end_of_track" });
        }
      } else if (statusByte === 0xF0 || statusByte === 0xF7) {
        // SysEx
        const len = r.readVarLen();
        r.readBytes(len);
      } else if (type === 0x9) {
        // Note On
        const note     = r.readUint8();
        const velocity = r.readUint8();
        events.push({ deltaTime, type: velocity > 0 ? "noteOn" : "noteOff", channel, note, velocity });
      } else if (type === 0x8) {
        // Note Off
        const note     = r.readUint8();
        const velocity = r.readUint8();
        events.push({ deltaTime, type: "noteOff", channel, note, velocity });
      } else if (type === 0xA) {
        r.readUint8(); r.readUint8(); // aftertouch
      } else if (type === 0xB) {
        r.readUint8(); r.readUint8(); // control change
      } else if (type === 0xC) {
        r.readUint8(); // program change
      } else if (type === 0xD) {
        r.readUint8(); // channel pressure
      } else if (type === 0xE) {
        r.readUint8(); r.readUint8(); // pitch bend
      } else {
        // Unknown — skip 1 byte to avoid infinite loop
        r.pos++;
      }
    }

    r.pos = trackEnd; // safety
    tracks.push(events);
  }

  return { format, trackCount, timeDivision, tracks };
}

// ─────────────────────────────────────────────────────────
//  MIDI → Virtual Piano converter
// ─────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────
// CORRECT Virtual Piano key mapping
// Verified against the actual VP keyboard layout:
// Row 1 (low):  1 2 3 4 5 6 7 8 9 0 q w e r t y u i o p
// Row 2 (mid):  a s d f g h j k l z x c v b n m
// Black keys (CAPS = Shift held):
// Row 1 caps:   ! @ $ % ^ * ( Q W E T Y I O P
// Row 2 caps:   S D G H J L Z C V B N M
//
// MIDI note 60 = C4 (middle C) = VP key "t" ← this is the anchor
// ─────────────────────────────────────────────────────────
// ── VERIFIED VP KEY MAP (from official MAX Mapping image) ──
// White keys: 1=C2 2=D2 3=E2 4=F2 5=G2 6=A2 7=B2
//             8=C3 9=D3 0=E3 q=F3 w=G3 e=A3 r=B3
//             t=C4 y=D4 u=E4 i=F4 o=G4 p=A4 a=B4
//             s=C5 d=D5 f=E5 g=F5 h=G5 j=A5 k=B5
//             l=C6 z=D6 x=E6 c=F6 v=G6 b=A6 n=B6 m=C7
// Black keys (Shift+white below): uppercase = needs Shift
function midiToVP(note) {
  const vpMap = {
    36:"1",  37:"!",  38:"2",  39:"@",  40:"3",   // C2 D#2 D2 D#2 E2
    41:"4",  42:"$",  43:"5",  44:"%",  45:"6",  46:"^",  47:"7",
    48:"8",  49:"*",  50:"9",  51:"(",  52:"0",
    53:"q",  54:"Q",  55:"w",  56:"W",  57:"e",  58:"E",  59:"r",
    60:"t",  61:"T",  62:"y",  63:"Y",  64:"u",
    65:"i",  66:"I",  67:"o",  68:"O",  69:"p",  70:"P",  71:"a",
    72:"s",  73:"S",  74:"d",  75:"D",  76:"f",
    77:"g",  78:"G",  79:"h",  80:"H",  81:"j",  82:"J",  83:"k",
    84:"l",  85:"L",  86:"z",  87:"Z",  88:"x",
    89:"c",  90:"C",  91:"v",  92:"V",  93:"b",  94:"B",  95:"n",
    96:"m",  97:"M",
  };
  return vpMap[note] || null;
}

function convertMidiBuffer(buffer, songName, category) {
  let midi;
  try {
    midi = parseMidi(buffer);
  } catch(e) {
    throw new Error("MIDI parse failed: " + e.message);
  }

  const tpb = midi.timeDivision;
  let tempo = 500000; // default 120 BPM

  // Pass 1: collect tempo changes per track with absolute ticks
  // Then collect noteOn events across ALL tracks with real ms timing
  const allEvents = [];

  // Build a merged tempo map first (format 1 has tempo in track 0)
  const tempoMap = [{ tick: 0, tempo: 500000 }];
  for (const track of midi.tracks) {
    let absTick = 0;
    for (const ev of track) {
      absTick += ev.deltaTime;
      if (ev.type === "tempo") {
        tempoMap.push({ tick: absTick, tempo: ev.tempo });
      }
    }
  }
  tempoMap.sort((a,b) => a.tick - b.tick);

  // Convert ticks to milliseconds using tempo map
  function ticksToMs(ticks) {
    let ms = 0;
    let lastTick = 0;
    let lastTempo = 500000;
    for (const t of tempoMap) {
      if (t.tick >= ticks) break;
      ms += ((Math.min(t.tick, ticks) - lastTick) / tpb) * (lastTempo / 1000);
      lastTick = t.tick;
      lastTempo = t.tempo;
    }
    ms += ((ticks - lastTick) / tpb) * (lastTempo / 1000);
    return ms;
  }

  // Pass 2: collect all noteOn events with correct ms timing
  for (const track of midi.tracks) {
    let absTick = 0;
    for (const ev of track) {
      absTick += ev.deltaTime;
      if (ev.type === "noteOn") {
        const vpKey = midiToVP(ev.note);
        if (vpKey) {
          allEvents.push({ vpKey, ms: ticksToMs(absTick), midi: ev.note });
        }
      }
    }
  }

  if (allEvents.length === 0) throw new Error("No playable notes found in this MIDI file");

  // Sort by time
  allEvents.sort((a,b) => a.ms - b.ms);

  // ── Group notes into chords then build the notes array ──
  // CHORD_WINDOW: notes within this many ms of each other = same chord
  const CHORD_WINDOW = 40; // ms

  // Step 1: group allEvents into chord groups
  const chordGroups = [];
  let i = 0;
  while (i < allEvents.length) {
    const group = { keys: [allEvents[i].vpKey], ms: allEvents[i].ms };
    i++;
    // Keep collecting notes that fall within the chord window
    while (i < allEvents.length && (allEvents[i].ms - group.ms) <= CHORD_WINDOW) {
      group.keys.push(allEvents[i].vpKey);
      i++;
    }
    chordGroups.push(group);
  }

  // Step 2: build notes array
  // For chords: all keys in chord get d=0 EXCEPT the last which gets the real delay
  const notes = [];
  for (let g = 0; g < chordGroups.length; g++) {
    const group  = chordGroups[g];
    const next   = chordGroups[g + 1];
    const delay  = next ? Math.max(0, Math.round(next.ms - group.ms)) : 0;

    for (let k = 0; k < group.keys.length; k++) {
      const isLastInChord = (k === group.keys.length - 1);
      // d=0 on all chord notes except last which carries the post-chord delay
      notes.push({ k: group.keys[k], d: isLastInChord ? delay : 0 });
    }
  }

  // Legacy sheet string for backwards compatibility
  const sheet = chordGroups.map(g => g.keys.join("+")).join(" ");

  return {
    name:      songName,
    category:  category || "Custom",
    sheet,     // legacy: "t+i+o y u" (+ = chord)
    notes,     // timed: [{k:"t",d:0},{k:"i",d:0},{k:"o",d:250},...]
    source:    "midi-converted",
    bpm:       Math.round(60000000 / tempoMap[0].tempo),
    noteCount: notes.length,
    chords:    chordGroups.filter(g => g.keys.length > 1).length,
  };
}

// ─────────────────────────────────────────────────────────
//  GitHub helpers
// ─────────────────────────────────────────────────────────

async function getFileSHA(filePath) {
  try {
    const { data } = await octokit.repos.getContent({
      owner: GITHUB_OWNER, repo: GITHUB_REPO,
      path: filePath, ref: GITHUB_BRANCH,
    });
    return data.sha;
  } catch { return null; }
}

async function getSongFilenames() {
  try {
    const { data } = await octokit.repos.getContent({
      owner: GITHUB_OWNER, repo: GITHUB_REPO,
      path: "songs", ref: GITHUB_BRANCH,
    });
    if (!Array.isArray(data)) return [];
    return data.filter(f => f.type==="file" && f.name.endsWith(".json")).map(f => f.name);
  } catch(e) {
    console.error("getSongFilenames:", e.message);
    return [];
  }
}

async function syncIndex(triggeredBy="server") {
  console.log(`[sync] Triggered by: ${triggeredBy}`);
  io.emit("sync_status", { status:"scanning", message:"Scanning songs/ folder..." });

  const filenames = await getSongFilenames();
  console.log(`[sync] Found ${filenames.length} files`);

  const encoded = Buffer.from(JSON.stringify(filenames, null, 2)).toString("base64");
  const sha     = await getFileSHA("index.json");

  try {
    await octokit.repos.createOrUpdateFileContents({
      owner: GITHUB_OWNER, repo: GITHUB_REPO,
      path: "index.json",
      message: `Auto-sync index.json (${filenames.length} songs) [${triggeredBy}]`,
      content: encoded, branch: GITHUB_BRANCH,
      ...(sha ? { sha } : {}),
    });
    const result = { status:"done", count:filenames.length, files:filenames };
    io.emit("sync_status", { ...result, message:`index.json updated — ${filenames.length} songs` });
    io.emit("songs_updated", result);
    console.log(`[sync] Done — ${filenames.length} songs`);
    return result;
  } catch(e) {
    console.error("[sync] Error:", e.message);
    io.emit("sync_status", { status:"error", message:e.message });
    throw e;
  }
}

async function uploadSongToGitHub(songData, filename) {
  const encoded = Buffer.from(JSON.stringify(songData, null, 2)).toString("base64");
  const sha     = await getFileSHA(`songs/${filename}`);
  await octokit.repos.createOrUpdateFileContents({
    owner: GITHUB_OWNER, repo: GITHUB_REPO,
    path: `songs/${filename}`,
    message: `Add song: ${songData.name}`,
    content: encoded, branch: GITHUB_BRANCH,
    ...(sha ? { sha } : {}),
  });
}

// ─────────────────────────────────────────────────────────
//  Routes
// ─────────────────────────────────────────────────────────

app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

app.get("/health", (req, res) => {
  res.json({ status:"ok", uptime: process.uptime() });
});

app.post("/sync", async (req, res) => {
  try {
    const result = await syncIndex(req.body?.source || "api");
    res.json({ success:true, ...result });
  } catch(e) {
    res.status(500).json({ success:false, error:e.message });
  }
});

app.get("/index", async (req, res) => {
  try {
    const files = await getSongFilenames();
    res.json({ success:true, count:files.length, files });
  } catch(e) {
    res.status(500).json({ success:false, error:e.message });
  }
});

// Convert MIDI + optionally upload to GitHub
app.post("/convert", upload.single("midi"), async (req, res) => {
  if (!req.file) return res.status(400).json({ success:false, error:"No MIDI file" });
  const songName   = req.body.name     || path.basename(req.file.originalname, path.extname(req.file.originalname));
  const category   = req.body.category || "Custom";
  const autoUpload = req.body.upload   === "true";
  try {
    const songData = convertMidiBuffer(req.file.buffer, songName, category);
    const filename = songName.toLowerCase().replace(/[^a-z0-9]/g,"_") + ".json";
    if (autoUpload) {
      await uploadSongToGitHub(songData, filename);
      await syncIndex("midi-upload");
      io.emit("song_added", { filename, name:songName });
    }
    res.json({ success:true, filename, songData, uploaded:autoUpload,
      preview: songData.sheet.slice(0,120) + (songData.sheet.length>120?"...":"") });
  } catch(e) {
    console.error("[convert]", e.message);
    res.status(500).json({ success:false, error:e.message });
  }
});

// Convert + download (no GitHub upload)
app.post("/convert/download", upload.single("midi"), async (req, res) => {
  if (!req.file) return res.status(400).json({ success:false, error:"No file" });
  const songName = req.body.name     || path.basename(req.file.originalname, path.extname(req.file.originalname));
  const category = req.body.category || "Custom";
  try {
    const songData = convertMidiBuffer(req.file.buffer, songName, category);
    const filename = songName.toLowerCase().replace(/[^a-z0-9]/g,"_") + ".json";
    res.setHeader("Content-Disposition", `attachment; filename="${filename}"`);
    res.setHeader("Content-Type", "application/json");
    res.send(JSON.stringify(songData, null, 2));
  } catch(e) {
    res.status(500).json({ success:false, error:e.message });
  }
});

// ─────────────────────────────────────────────────────────
//  Socket.io
// ─────────────────────────────────────────────────────────

io.on("connection", (socket) => {
  console.log(`[socket] Connected: ${socket.id}`);

  socket.on("roblox_loaded", async () => {
    console.log(`[socket] Roblox load from ${socket.id}`);
    try { await syncIndex("roblox_load"); }
    catch(e) { socket.emit("sync_status", { status:"error", message:e.message }); }
  });

  socket.on("request_sync", async () => {
    try { await syncIndex("roblox_reload"); }
    catch(e) { socket.emit("sync_status", { status:"error", message:e.message }); }
  });

  socket.on("disconnect", () => console.log(`[socket] Disconnected: ${socket.id}`));
});

// ─────────────────────────────────────────────────────────
//  Start
// ─────────────────────────────────────────────────────────

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`\n🎹 Auto Piano Sync Server on port ${PORT}`);
  console.log(`   GitHub: ${GITHUB_OWNER}/${GITHUB_REPO} @ ${GITHUB_BRANCH}\n`);
});
