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

// Maps MIDI note number to Virtual Piano key
// MIDI 60 = middle C (C4) = VP key "t"
function midiToVP(note) {
  // Semitone within octave
  const semi = note % 12;
  const oct  = Math.floor(note / 12) - 1; // MIDI octave

  // White key semitones: C=0 D=2 E=4 F=5 G=7 A=9 B=11
  // Black key semitones: C#=1 D#=3 F#=6 G#=8 A#=10

  const isBlack = [1,3,6,8,10].includes(semi);

  // Full VP keyboard layout mapped by MIDI note number
  const vpMap = {
    // Octave 2 (24–35)
    24:"1",25:"@",26:"2",27:"%",28:"3",29:"4",30:"^",31:"5",32:"*",33:"6",34:"(",35:"7",
    // Octave 3 (36–47)
    36:"8",37:"W",38:"9",39:"R",40:"0",41:"q",42:"Y",43:"w",44:"I",45:"e",46:"P",47:"r",
    // Octave 4 (48–59)
    48:"t",49:"S",50:"y",51:"F",52:"u",53:"i",54:"H",55:"o",56:"J",57:"p",58:"L",59:"a",
    // Octave 5 (60–71)  ← middle C = 60 = "s"
    60:"s",61:"Z",62:"d",63:"C",64:"f",65:"g",66:"B",67:"h",68:"N",69:"j",70:"M",71:"k",
    // Octave 6 (72–83)
    72:"l",73:null,74:"z",75:null,76:"x",77:"c",78:null,79:"v",80:null,81:"b",82:null,83:"n",
    // Octave 7 (84+)
    84:"m",
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

  const tpb    = midi.timeDivision; // ticks per beat
  let   tempo  = 500000;            // microseconds per beat (default 120 BPM)

  // Collect all noteOn events with absolute tick times
  const allEvents = [];

  for (const track of midi.tracks) {
    let absTick = 0;
    for (const ev of track) {
      absTick += ev.deltaTime;
      if (ev.type === "tempo") {
        tempo = ev.tempo;
      }
      if (ev.type === "noteOn") {
        const vpKey = midiToVP(ev.note);
        if (vpKey) {
          const ms = (absTick / tpb) * (tempo / 1000);
          allEvents.push({ vpKey, ms });
        }
      }
    }
  }

  if (allEvents.length === 0) throw new Error("No playable notes found in this MIDI file");

  // Sort by time
  allEvents.sort((a,b) => a.ms - b.ms);

  // Build sheet string
  let sheet = "";
  let count = 0;
  for (const ev of allEvents) {
    sheet += ev.vpKey + " ";
    count++;
    if (count % 8 === 0) sheet += "| ";
  }
  sheet = sheet.trim();

  return {
    name:     songName,
    category: category || "Custom",
    sheet,
    source:   "midi-converted",
    notes:    allEvents.length,
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
server.listen(PORT, async () => {
  console.log(`\n🎹 Auto Piano Sync Server on port ${PORT}`);
  console.log(`   GitHub: ${GITHUB_OWNER}/${GITHUB_REPO} @ ${GITHUB_BRANCH}\n`);

  // ── Auto-sync on every server start/restart ──
  console.log("[startup] Syncing index.json...");
  try {
    await syncIndex("server_startup");
    console.log("[startup] Done!");
  } catch(e) {
    console.error("[startup] Sync failed:", e.message);
  }

  // ── Re-sync every 5 minutes as safety net ──
  setInterval(async () => {
    try { await syncIndex("interval_5min"); }
    catch(e) { console.error("[interval] error:", e.message); }
  }, 5 * 60 * 1000);
});

// ─────────────────────────────────────────────────────────
//  GitHub Webhook endpoint
//  In your Piano-player repo: Settings → Webhooks → Add webhook
//  Payload URL: https://YOUR-RENDER-URL.onrender.com/webhook
//  Content type: application/json  |  Events: Just the push event
// ─────────────────────────────────────────────────────────

app.post("/webhook", async (req, res) => {
  const event = req.headers["x-github-event"];
  console.log(`[webhook] GitHub event: ${event}`);
  if (event === "push") {
    const commits = req.body?.commits || [];
    const touchesSongs = commits.some(c =>
      [...(c.added||[]), ...(c.modified||[]), ...(c.removed||[])]
        .some(f => f.startsWith("songs/"))
    );
    if (touchesSongs) {
      console.log("[webhook] songs/ changed — syncing...");
      res.json({ received: true, syncing: true });
      try { await syncIndex("github_webhook"); }
      catch(e) { console.error("[webhook] error:", e.message); }
    } else {
      res.json({ received: true, syncing: false, reason: "no songs/ changes" });
    }
  } else {
    res.json({ received: true, event });
  }
});
