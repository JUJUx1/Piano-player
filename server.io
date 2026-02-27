// ╔══════════════════════════════════════════════════════════╗
// ║  Auto Piano Sync Server                                  ║
// ║  - Socket.io: notifies Roblox clients of updates        ║
// ║  - GitHub API: scans songs/ folder → updates index.json ║
// ║  - MIDI Converter: uploads .mid → generates song JSON   ║
// ╚══════════════════════════════════════════════════════════╝

require("dotenv").config();
const express     = require("express");
const http        = require("http");
const { Server }  = require("socket.io");
const cors        = require("cors");
const multer      = require("multer");
const path        = require("path");
const MidiParser  = require("midi-parser-js");
const { Octokit } = require("@octokit/rest");

const app    = express();
const server = http.createServer(app);
const io     = new Server(server, {
  cors: { origin: "*", methods: ["GET", "POST"] }
});

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 5 * 1024 * 1024 } });

// ── GitHub Config (from .env) ──────────────────────────────
const GITHUB_TOKEN  = process.env.GITHUB_TOKEN;
const GITHUB_OWNER  = process.env.GITHUB_OWNER;
const GITHUB_REPO   = process.env.GITHUB_REPO   || "piano-songs";
const GITHUB_BRANCH = process.env.GITHUB_BRANCH || "main";

const octokit = new Octokit({ auth: GITHUB_TOKEN });

// ── Helper: get file SHA (needed to update existing files) ──
async function getFileSHA(filePath) {
  try {
    const { data } = await octokit.repos.getContent({
      owner: GITHUB_OWNER, repo: GITHUB_REPO,
      path: filePath, ref: GITHUB_BRANCH,
    });
    return data.sha;
  } catch (e) {
    return null; // file doesn't exist yet
  }
}

// ── Helper: list all .json files inside songs/ folder ───────
async function getSongFilenames() {
  try {
    const { data } = await octokit.repos.getContent({
      owner: GITHUB_OWNER, repo: GITHUB_REPO,
      path: "songs", ref: GITHUB_BRANCH,
    });
    if (!Array.isArray(data)) return [];
    return data
      .filter(f => f.type === "file" && f.name.endsWith(".json"))
      .map(f => f.name);
  } catch (e) {
    console.error("getSongFilenames error:", e.message);
    return [];
  }
}

// ── Core: scan songs/ folder and update index.json ──────────
async function syncIndex(triggeredBy = "server") {
  console.log(`[sync] Triggered by: ${triggeredBy}`);
  io.emit("sync_status", { status: "scanning", message: "Scanning songs/ folder..." });

  const filenames = await getSongFilenames();
  console.log(`[sync] Found ${filenames.length} song files:`, filenames);

  const indexContent = JSON.stringify(filenames, null, 2);
  const encoded      = Buffer.from(indexContent).toString("base64");
  const sha          = await getFileSHA("index.json");

  try {
    await octokit.repos.createOrUpdateFileContents({
      owner:   GITHUB_OWNER,
      repo:    GITHUB_REPO,
      path:    "index.json",
      message: `Auto-sync index.json (${filenames.length} songs) [${triggeredBy}]`,
      content: encoded,
      branch:  GITHUB_BRANCH,
      ...(sha ? { sha } : {}),
    });

    const result = { status: "done", count: filenames.length, files: filenames };
    console.log(`[sync] index.json updated with ${filenames.length} songs`);
    io.emit("sync_status", { ...result, message: `index.json updated — ${filenames.length} songs` });
    io.emit("songs_updated", { count: filenames.length, files: filenames });
    return result;
  } catch (e) {
    console.error("[sync] GitHub write error:", e.message);
    io.emit("sync_status", { status: "error", message: e.message });
    throw e;
  }
}

// ╔══════════════════════════════════════════════════════════╗
// ║  MIDI → Virtual Piano Sheet Converter                    ║
// ╚══════════════════════════════════════════════════════════╝

// Virtual Piano key mapping (MIDI note number → VP key)
// MIDI 60 = C4 (middle C)
const MIDI_TO_VP = {};

// White keys: C D E F G A B across octaves
// VP layout: 1 2 3 4 5 6 7 8 9 0 q w e r t y u i o p a s d f g h j k l z x c v b n m
const WHITE_KEYS = [
  //  C    D    E    F    G    A    B
  // Octave 1 (MIDI 24-35)
  null, null, null, null, null, null, null,
  // Octave 2 (MIDI 36-47) → VP: 1 2 3 4 5 6 7
  "1","2","3","4","5","6","7",
  // Octave 3 (MIDI 48-59) → VP: 8 9 0 q w e r
  "8","9","0","q","w","e","r",
  // Octave 4 (MIDI 60-71) → VP: t y u i o p a  (middle C = t)
  "t","y","u","i","o","p","a",
  // Octave 5 (MIDI 72-83) → VP: s d f g h j k
  "s","d","f","g","h","j","k",
  // Octave 6 (MIDI 84-95) → VP: l z x c v b n
  "l","z","x","c","v","b","n",
  // Octave 7 (MIDI 96-107) → VP: m
  "m",
];

const BLACK_KEYS = [
  // Octave 2 (MIDI 37,39,42,44,46) → VP CAPS
  null,"@",null,"%",null,null,"^",null,"*",null,"(",null,
  // Octave 3
  null,"W",null,"R",null,null,"Y",null,"I",null,"P",null,
  // Octave 4
  null,"S",null,"F",null,null,"H",null,"J",null,"L",null,
  // Octave 5
  null,"Z",null,"C",null,null,"B",null,"N",null,"M",null,
  // Octave 6
  null,null,null,null,null,null,null,null,null,null,null,null,
];

function midiNoteToVP(midiNote) {
  if (midiNote < 24 || midiNote > 107) return null;
  const offset = midiNote - 24;

  // Semitone pattern within octave: C C# D D# E F F# G G# A A# B
  const semitone = midiNote % 12;
  const isBlack  = [1,3,6,8,10].includes(semitone);

  if (isBlack) {
    return BLACK_KEYS[offset] || null;
  } else {
    return WHITE_KEYS[offset] || null;
  }
}

function convertMidiBuffer(buffer, songName, category) {
  const uint8 = new Uint8Array(buffer);
  let parsed;

  try {
    parsed = MidiParser.parse(uint8);
  } catch (e) {
    throw new Error("Failed to parse MIDI: " + e.message);
  }

  const ticksPerBeat = parsed.timeDivision || 480;
  let tempo = 500000; // default 120 BPM

  // Collect all note events with absolute times
  const events = [];

  for (const track of parsed.track) {
    let absoluteTick = 0;
    for (const event of track.event) {
      absoluteTick += event.deltaTime || 0;

      if (event.type === 0xFF && event.metaType === 0x51) {
        // Tempo change
        tempo = event.data;
      }

      if ((event.type === 0x09 || event.type === 9) && event.data[1] > 0) {
        // Note on with velocity > 0
        const vpKey = midiNoteToVP(event.data[0]);
        if (vpKey) {
          const timeMs = (absoluteTick / ticksPerBeat) * (tempo / 1000);
          events.push({ key: vpKey, timeMs });
        }
      }
    }
  }

  if (events.length === 0) {
    throw new Error("No playable notes found in MIDI file");
  }

  // Sort by time
  events.sort((a, b) => a.timeMs - b.timeMs);

  // Build sheet string with timing
  // Group notes that happen at (nearly) the same time
  const CHORD_THRESHOLD = 30; // ms — notes within this are "simultaneous"
  const MIN_GAP = 80; // ms minimum gap to insert a separator

  let sheet = "";
  let prevTime = events[0].timeMs;
  let noteCount = 0;

  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    const gap = ev.timeMs - prevTime;

    if (i > 0 && gap > MIN_GAP) {
      // Insert bar separator every ~8 notes for readability
      if (noteCount > 0 && noteCount % 8 === 0) sheet += "| ";
    }

    sheet += ev.key + " ";
    prevTime = ev.timeMs;
    noteCount++;
  }

  sheet = sheet.trim();

  return {
    name:     songName,
    category: category || "Custom",
    sheet:    sheet,
    source:   "midi-converted",
    notes:    events.length,
  };
}

// ── Upload a converted song to GitHub ───────────────────────
async function uploadSongToGitHub(songData, filename) {
  const content = JSON.stringify(songData, null, 2);
  const encoded = Buffer.from(content).toString("base64");
  const sha     = await getFileSHA(`songs/${filename}`);

  await octokit.repos.createOrUpdateFileContents({
    owner:   GITHUB_OWNER,
    repo:    GITHUB_REPO,
    path:    `songs/${filename}`,
    message: `Add song: ${songData.name}`,
    content: encoded,
    branch:  GITHUB_BRANCH,
    ...(sha ? { sha } : {}),
  });
}

// ╔══════════════════════════════════════════════════════════╗
// ║  REST ENDPOINTS                                          ║
// ╚══════════════════════════════════════════════════════════╝

// Health check
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

app.get("/health", (req, res) => {
  res.json({ status: "ok", server: "Auto Piano Sync", uptime: process.uptime() });
});

// Manual sync trigger (called by Roblox on script load or reload)
app.post("/sync", async (req, res) => {
  const triggeredBy = req.body?.source || "api";
  try {
    const result = await syncIndex(triggeredBy);
    res.json({ success: true, ...result });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// GET current index (reads from GitHub)
app.get("/index", async (req, res) => {
  try {
    const files = await getSongFilenames();
    res.json({ success: true, count: files.length, files });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// Upload + convert a MIDI file
app.post("/convert", upload.single("midi"), async (req, res) => {
  if (!req.file) return res.status(400).json({ success: false, error: "No MIDI file uploaded" });

  const songName  = req.body.name     || path.basename(req.file.originalname, ".mid");
  const category  = req.body.category || "Custom";
  const autoUpload = req.body.upload === "true";

  try {
    const songData = convertMidiBuffer(req.file.buffer, songName, category);
    const filename = songName.toLowerCase().replace(/[^a-z0-9]/g, "_") + ".json";

    if (autoUpload) {
      await uploadSongToGitHub(songData, filename);
      // Auto-sync index after upload
      await syncIndex("midi-upload");
      io.emit("song_added", { filename, name: songName });
    }

    res.json({
      success:  true,
      filename,
      songData,
      uploaded: autoUpload,
      preview:  songData.sheet.slice(0, 120) + (songData.sheet.length > 120 ? "..." : ""),
    });
  } catch (e) {
    console.error("[convert] Error:", e.message);
    res.status(500).json({ success: false, error: e.message });
  }
});

// Download converted song JSON directly (without GitHub upload)
app.post("/convert/download", upload.single("midi"), async (req, res) => {
  if (!req.file) return res.status(400).json({ success: false, error: "No file" });

  const songName = req.body.name     || path.basename(req.file.originalname, ".mid");
  const category = req.body.category || "Custom";

  try {
    const songData = convertMidiBuffer(req.file.buffer, songName, category);
    const filename = songName.toLowerCase().replace(/[^a-z0-9]/g, "_") + ".json";
    res.setHeader("Content-Disposition", `attachment; filename="${filename}"`);
    res.setHeader("Content-Type", "application/json");
    res.send(JSON.stringify(songData, null, 2));
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ╔══════════════════════════════════════════════════════════╗
// ║  SOCKET.IO                                               ║
// ╚══════════════════════════════════════════════════════════╝

io.on("connection", (socket) => {
  const clientIp = socket.handshake.address;
  console.log(`[socket] Client connected: ${socket.id} (${clientIp})`);

  // When Roblox script loads → trigger index sync
  socket.on("roblox_loaded", async (data) => {
    console.log(`[socket] Roblox loaded event from ${socket.id}:`, data);
    socket.emit("sync_status", { status: "scanning", message: "Syncing index..." });
    try {
      await syncIndex("roblox_load");
    } catch (e) {
      socket.emit("sync_status", { status: "error", message: e.message });
    }
  });

  // Manual reload request from Roblox
  socket.on("request_sync", async () => {
    try {
      await syncIndex("roblox_reload");
    } catch (e) {
      socket.emit("sync_status", { status: "error", message: e.message });
    }
  });

  socket.on("disconnect", () => {
    console.log(`[socket] Client disconnected: ${socket.id}`);
  });
});

// ── Start server ─────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`\n🎹 Auto Piano Sync Server running on port ${PORT}`);
  console.log(`   GitHub: ${GITHUB_OWNER}/${GITHUB_REPO} (${GITHUB_BRANCH})`);
  console.log(`   Dashboard: http://localhost:${PORT}\n`);
});
