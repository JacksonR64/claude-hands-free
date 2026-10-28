import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

const PLAYERS = ['Music', 'Spotify']

// plain-text a markdown reply for the synthesizer
const clean = (s: string) =>
  s.replace(/```[\s\S]*?```/g, ' code block. ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[*_#>|~-]{1,}/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()

function osa($: any, script: string) {
  return $.process.run(['osascript', '-e', script])
}
async function state($: any, app: string) {
  const r = await osa($, `if application "${app}" is running then tell application "${app}" to return player state as string`).catch(() => ({ stdout: '' }))
  return r.stdout.trim()
}


function log($: any, m: string) {
  return $.process.run(['sh', '-c', `echo "$(TZ=Europe/London date '+%F %T') ${m.replace(/["`$\\]/g, '')}" >> /tmp/read-aloud.log`]).catch(() => {})
}

const LOCK = '/tmp/read-aloud.lock' // shared by every session: one item spoken at a time

const STOP = '/tmp/read-aloud.stop' // touched by Option+S: whichever session is speaking drops its item
const INBOX = '/tmp/read-aloud-inbox' // text files dropped here are spoken once, then deleted
const MAX_CHUNK = 200 // `say` is killed after 30 s, so long sentences are split

const phase = atom({ plugin: 'read-aloud', key: 'phase' } as const, 'idle')
const who = atom({ plugin: 'read-aloud', key: 'who' } as const, '')


// mkdir is atomic: first session to make the dir holds the lock; a lock over 10 min old is stale
async function takeLock($: any, mine: number) {
  for (;;) {
    if (gen !== mine) return false
    await $.process.run(['find', LOCK, '-maxdepth', '0', '-mmin', '+10', '-exec', 'rmdir', '{}', ';']).catch(() => {})
    const pr = String(await $.fs.read(`${DIR}/priority`).catch(() => '')).trim()
    if (pr && pr !== myId && (await $.fs.exists(`${DIR}/s-${pr}.json`).catch(() => false))) { await $.clock.sleep(300); continue }
    const r = await $.process.run(['mkdir', LOCK]).then((x: any) => x.exitCode === 0, () => false) // run() resolves on non-zero exit too
    if (r) {
      if (pr === myId) await $.process.run(['rm', '-f', `${DIR}/priority`]).catch(() => {})
      return true
    }
    await $.clock.sleep(300)
  }
}

const RESUME_MS = 1000
const PAUSE_LIMIT_MS = 300000 // a pause (dictation) may last 5 minutes; the lock goes stale at 10
let live = false // paused by Option+Space
let resumeAt = 0
let speaking = false
let gen = 0 // bumped to cancel any speech in flight
let cut = false // current sentence was killed by a pause
let cadence = true
let myId = ''
let myName = ''
let cur = 'idle'
let lastCmd = 0
let myLocal = ''
let myTitle = ''
let choices: { k: string; l: string }[] = []
let progI = 0
let progN = 0
let settings = { rate: 0, rewrite: true, gap: 4, manual: false, follow: false, voice: false, reading: true }
let progText = ''
let approved = false
const DIR = '/tmp/read-aloud' // existing speech files; private session IPC lives in CONTROL
let CONTROL = ''
let instance = ''
let activeTurn = ''
let lastAnswer = ''
let cwd = ''
let pending: any[] = []
let polling = false
let publishing = false
let commandBusy = false
let startedAt = 0
let requestCount = 0
let connected = false

async function bridge($: any, operation: string, ...args: string[]) {
  const result = await $.process.run(['python3', `${$.plugin.root}/bin/bridge.py`, operation, ...args], { timeoutMs: operation === 'wait' ? 310000 : 10000 })
  if (result.exitCode !== 0) throw new Error(result.stderr || 'Conversation bridge failed')
  return result.stdout
}

// the panel holds a lock while it runs; with no panel nobody can answer by voice or click, so the host's own prompt must show
async function controllerAlive($: any) {
  try { return (await bridge($, 'alive')).trim() === '1' } catch { return false }
}

function displayName() { return myTitle || cwd.split('/').pop() || 'Claude session' }

async function publish($: any) {
  if (!connected || !myId || !CONTROL || publishing) return
  publishing = true
  try {
    await bridge($, 'publish', JSON.stringify({ id: myId, instance, name: displayName(), local: myLocal, cwd,
      phase: cur, work: pending.length ? pending[0].kind : activeTurn ? 'working' : 'idle', pending,
      i: progI, n: progN, text: progText, choices, ready: !!lastAnswer, startedAt, ts: await $.clock.now() }))
  } finally { publishing = false }
}

async function acknowledge($: any, command: any, status: string, detail = '') {
  await bridge($, 'ack', JSON.stringify(command), status, detail)
}

async function selected($: any) {
  try {
    const selection = JSON.parse(await $.fs.read(`${CONTROL}/selection.json`))
    return selection.session === myId && selection.instance === instance
  } catch { return false }
}

async function submitVoice($: any, command: any) {
  if (pending.length) { await acknowledge($, command, 'failed', 'Answer the pending request first.'); return }
  await stopNow($)
  await acknowledge($, command, 'queued', activeTurn ? 'Queued until the current work finishes' : 'Waiting for Claude to start')
  try {
    const result = await $.prompt.submit({ text: command.text, asUser: true })
    await acknowledge($, command, result?.drop ? 'failed' : 'started', result?.drop || 'Claude started this message')
  } catch (error) { await acknowledge($, command, 'failed', String(error)) }
}

function requestSpeech(request: any) {
  return request.kind === 'permission'
    ? `Approval requested. ${request.tool}. ${request.detail}. Say approve action or deny action.`
    : request.question + (request.options?.length ? '. Options: ' + request.options.join(', ') : '')
}

async function readCurrent($: any) {
  await loadSettings($)
  await stopNow($)
  const mine = gen
  const raw = pending.length ? requestSpeech(pending[0]) : lastAnswer
  const text = pending.length ? raw : raw ? await spoken($, raw, true) : `Talking to ${displayName()}.`
  if (gen === mine && await selected($)) await speak($, 'reply', displayName(), text, mine, !!raw)
}

async function pollControl($: any) {
  if (!connected || polling) return
  polling = true
  try {
    const commands = JSON.parse(await bridge($, 'drain', myId, instance))
    for (const command of commands) {
      try {
        if (command.verb === 'reply') {
          if (commandBusy) { await acknowledge($, command, 'failed', 'A voice message is already queued.'); continue }
          commandBusy = true
          submitVoice($, command).catch(error => $.ui.log(String(error), { to: 'debug' })).finally(() => { commandBusy = false })
        } else if (command.verb === 'abort') {
          if (!activeTurn) { await acknowledge($, command, 'failed', 'No running turn to stop'); continue }
          const turnId = activeTurn
          await stopNow($)
          await $.turn.abort({ turnId })
          await acknowledge($, command, 'done', 'Work stopped; completed actions are not undone')
        } else {
          if (command.verb === 'toggle') await togglePause($)
          else if (command.verb === 'stop' || command.verb === 'drop') await stopNow($)
          else if (command.verb === 'play') approved = true
          else if (command.verb === 'read') readCurrent($).catch(error => $.ui.log(String(error), { to: 'debug' }))
          await acknowledge($, command, 'done')
        }
      } catch (error) { await acknowledge($, command, 'failed', String(error)) }
    }
  } catch (error) { $.ui.log(String(error), { to: 'debug' }) }
  finally { polling = false }
}

async function waitForAnswer($: any, request: any) {
  const owner = instance
  pending.push(request)
  await publish($)
  if (pending[0]?.id === request.id && await selected($)) readCurrent($).catch(error => $.ui.log(String(error), { to: 'debug' }))
  try {
    const result = JSON.parse(await bridge($, 'wait', myId, instance, request.id, '300'))
    if (result.error) throw new Error(result.error)
    return result.text
  } finally {
    if (instance === owner && connected) {
      pending = pending.filter(value => value.id !== request.id)
      await stopNow($)
      await publish($)
      if (pending.length && await selected($)) readCurrent($).catch(error => $.ui.log(String(error), { to: 'debug' }))
    }
  }
}

// lettered options (A. / B) / Option C:) or a closing yes/no question, so the card can offer one-tap answers
function findChoices(a: string) {
  const seen = new Set<string>()
  const opts: { k: string; l: string }[] = []
  for (const m of a.matchAll(/^\s*(?:[-*]\s*)?\*{0,2}(?:Option\s+)?([A-E])[.):]\*{0,2}\s+(.{2,90})/gm)) {
    if (seen.has(m[1])) continue
    seen.add(m[1])
    opts.push({ k: m[1], l: m[2].replace(/[*_`]/g, '').trim() })
  }
  if (opts.length >= 2 && opts[0].k === 'A') return opts
  const tail = a.trim().split('\n').pop() ?? ''
  if (/\?\s*\**$/.test(tail) && /\b(shall I|should I|want me to|do you want|ok to|okay to|go ahead|proceed|ready to)\b/i.test(tail)) return [{ k: 'Yes', l: '' }, { k: 'No', l: '' }]
  return []
}

// ~/.config/read-aloud/settings.json is edited by the status card; /cadence writes it too
async function loadSettings($: any) {
  const r = await $.process.run(['sh', '-c', 'cat "$HOME/.config/read-aloud/settings.json" 2>/dev/null']).catch(() => ({ stdout: '' }))
  try {
    const j = JSON.parse(r.stdout)
    settings = { rate: Number(j.rate) || 0, rewrite: j.rewrite !== false, gap: Number(j.gap) > 0 ? Number(j.gap) : 4, manual: j.manual === true, follow: j.follow === true, voice: j.voice === true, reading: j.reading !== false }
  } catch {}
  cadence = settings.rewrite
}
function writeSetting($: any, key: string, val: any) {
  return $.process.run(['python3', '-c', "import json,os,sys;p=os.path.expanduser('~/.config/read-aloud/settings.json');os.makedirs(os.path.dirname(p),exist_ok=True);d=json.load(open(p)) if os.path.exists(p) else {};d[sys.argv[1]]=json.loads(sys.argv[2]);json.dump(d,open(p,'w'))", key, JSON.stringify(val)]).catch(() => {})
}
// title (a readable label for remote-control sessions) and the app's own id for this chat, from bin/session-info.py
async function findLocal($: any) {
  const r = await $.process.run(['python3', `${$.plugin.root}/bin/session-info.py`, myId]).catch(() => ({ stdout: '' }))
  try {
    const j = JSON.parse(r.stdout)
    myLocal = j.local || ''
    myTitle = j.title || ''
  } catch {}
}
async function sessionName($: any) {
  await findLocal($)
  return myTitle
}

// Keep idle sessions registered so voice selection survives after a reply.
async function setPhase($: any, p: string) {
  cur = p === 'idle' && choices.length ? 'answer' : p
  await update($, phase, () => cur)
  await publish($)
}

// the shared status card: compiled once to ~/.cache/read-aloud, started once by whichever session gets there first
async function ensureBar($: any) {
  const launched = await $.process.run(['sh', `${$.plugin.root}/bin/launch-panel.sh`], { timeoutMs: 120000 })
  if (launched.exitCode !== 0) throw new Error(launched.stderr || 'Could not start the conversation helpers')
}

// pause/resume (Option+Space, or the band's button): pausing kills the sentence, resuming repeats it after RESUME_MS
async function togglePause($: any) {
  live = !live
  if (live) {
    // only the session that is reading kills `say`; pkill is global and would cut other sessions and the relay
    if (speaking) cut = true
    if (speaking) await $.process.run(['pkill', '-x', 'afplay']).catch(() => {})
    if (speaking) await setPhase($, 'paused')
  } else {
    resumeAt = (await $.clock.now()) + RESUME_MS
    if (speaking) await setPhase($, 'speaking')
  }
}

// drop what is left of this session's items (new prompt); Option+S and the band's Stop also stop whichever session or the relay is speaking
async function stopNow($: any, everywhere = false) {
  gen++
  live = false
  if (everywhere) await $.process.run(['touch', STOP]).catch(() => {})
  if (everywhere || speaking) await $.process.run(['pkill', '-x', everywhere ? 'say|afplay' : 'afplay']).catch(() => {})
  await setPhase($, 'idle')
}

// keys.swift prints "toggle" (Option+Space), "stop" (Option+S) and "clip" (Option+R)
async function watchKeys($: any) {
  const id = await $.session.id()
  const pid = `/tmp/read-aloud-keys-${id}.pid`
  await $.process.run(['sh', '-c', `kill $(cat ${pid}) 2>/dev/null; true`]).catch(() => {})
  for await (const c of $.process.spawn({ argv: ['sh', '-c', `echo $$ > ${pid}; exec "$HOME/.cache/read-aloud/read-aloud-keys"`] })) {
    if (c.stream !== 'stdout') continue
    for (const word of c.text.split(/\s+/)) {
      if (word === 'toggle') await togglePause($)
      else if (word === 'stop') await stopNow($, true)
      else if (word === 'clip') readClipboard($).catch(() => {}) // not awaited: keys must stay live while it reads
      else if (word === 'noperm' || word === 'notap') await log($, 'keys: ' + word)
    }
  }
}

// a sentence over MAX_CHUNK is cut at commas/semicolons/colons, then at spaces, and repacked up to MAX_CHUNK
function chunks(sentence: string) {
  if (sentence.length <= MAX_CHUNK) return [sentence]
  const parts = sentence.split(/(?<=[,;:])\s+/).flatMap(p => (p.length <= MAX_CHUNK ? [p] : p.split(/\s+/)))
  const out: string[] = []
  let cur = ''
  for (const p of parts) {
    if (cur && cur.length + 1 + p.length > MAX_CHUNK) {
      out.push(cur)
      cur = p
    } else cur = cur ? cur + ' ' + p : p
  }
  if (cur) out.push(cur)
  return out
}

// render a piece to an audio file now, so playing it later cannot stall when the CPU is busy (live synthesis glitches under load)
async function render($: any, piece: string, i: number) {
  const file = `${DIR}/r-${myId}-${i}.aiff`
  const r = await $.process.run(['say', ...(settings.rate > 0 ? ['-r', String(settings.rate)] : []), '-o', file, piece]).catch(() => undefined)
  return r && r.exitCode === 0 ? file : ''
}

// play piece by piece (the next renders while this one plays); a piece cut by a pause is repeated from its start
async function speakAll($: any, text: string, mine: number) {
  const pieces = (text.match(/[^.!?]+[.!?]*\s*/g) ?? [text]).flatMap(s => chunks(s.trim())).filter(Boolean)
  if (!pieces.length) return
  await $.process.run(['mkdir', '-p', DIR]).catch(() => {})
  let next = render($, pieces[0], 0)
  try {
    for (let i = 0; i < pieces.length; i++) {
      const file = await next
      progI = i
      progN = pieces.length
      progText = pieces[i]
      await $.process.run(['touch', LOCK]).catch(() => {}) // keeps the lock fresh while paused
      await setPhase($, cur)
      if (i + 1 < pieces.length) next = render($, pieces[i + 1], i + 1)
      if (!file) continue
      for (;;) {
        if (gen !== mine) return
        // paused too long (e.g. Option+Space pressed for Handy without a matching second press): drop the item so the lock frees
        let pausedAt = 0
        while (live || (await $.clock.now()) < resumeAt) {
          const t = await $.clock.now()
          if (!live) pausedAt = 0
          else if (!pausedAt) pausedAt = t
          else if (t - pausedAt > PAUSE_LIMIT_MS) {
            live = false
            await log($, 'paused over 5 min: item dropped')
            return
          }
          await $.clock.sleep(100)
        }
        if (gen !== mine) return
        const stopped = await $.process.run(['test', STOP, '-nt', '/tmp/read-aloud.speaking']).then((x: any) => x.exitCode === 0, () => false)
        if (stopped) return
        cut = false
        speaking = true
        await $.process.run(['afplay', file]).catch((err: any) => log($, 'afplay failed ' + String(err)))
        speaking = false
        if (!cut || gen !== mine) break
      }
    }
  } finally {
    await $.process.run(['sh', '-c', `rm -f ${DIR}/r-${myId}-*.aiff`]).catch(() => {})
  }
}

// plain text for `say`; the Haiku rewrite runs for replies when /cadence is on, and for other text only if it looks like markdown or code
async function spoken($: any, raw: string, always: boolean) {
  const text = clean(raw)
  if (!cadence || (!always && !/```|`|\*\*|^#|^\s*[-*] |\|/m.test(raw))) return text
  const m = await $.model.complete({
    model: 'haiku',
    prompt: `Rewrite this reply as natural spoken English for text-to-speech, as a friendly person would say it aloud. Skip code, file paths, URLs, tables and anything unspeakable (mention briefly instead, e.g. "I've put the code in the chat"). Keep every real point, in the same order. Short sentences, plain words. Output only the spoken text.\n\n${raw}`,
  }).catch(() => undefined)
  return m && m.isAnswered && m.text ? m.text : text
}

// one item through the shared queue: lock, pause music, band, notification, log, speech
async function speak($: any, source: string, name: string, text: string, mine: number, prefix: boolean) {
  // The app is the master switch: no running app, or "Read replies aloud" off, means silence (Option+R still reads the clipboard)
  await loadSettings($)
  if (!(await controllerAlive($)) || (source !== 'clipboard' && !settings.reading)) return
  myName = name
  await setPhase($, 'queued')
  if (source === 'reply' && settings.manual) {
    approved = false
    while (!approved && gen === mine) await $.clock.sleep(300)  // the card's Play button (or "play next") sets it
    if (gen !== mine) return
  }
  if (!(await takeLock($, mine))) return
  const paused: string[] = []
  try {
    for (const app of PLAYERS)
      if ((await state($, app)) === 'playing') {
        await osa($, `tell application "${app}" to pause`).catch(() => {})
        paused.push(app)
      }
    await $.process.run(['touch', '/tmp/read-aloud.speaking']).catch(() => {})
    await update($, who, () => name)
    await setPhase($, 'speaking')
    if (source === 'reply' && settings.follow && myLocal) $.process.run(['open', `claude://code/continue?session=${myLocal}`]).catch(() => {})
    await osa($, `display notification "${name.replace(/["\\\\]/g, '')}" with title "Reading aloud"`).catch(() => {})
    await log($, `${source} | ${name} | ${text.split(/\s+/).slice(0, 8).join(' ')}`)
    await speakAll($, (prefix ? name + '. ' : '') + text, mine)
  } finally {
    await $.process.run(['rm', '-f', '/tmp/read-aloud.speaking']).catch(() => {})
    if (gen === mine) await setPhase($, 'idle')
    for (const app of paused) await osa($, `tell application "${app}" to play`).catch(() => {})
    await $.clock.sleep(settings.gap * 1000) // pause before the next item starts
    await $.process.run(['rmdir', LOCK]).catch(() => {})
  }
}

// Option+R: keys.swift swallows the key, so only one session gets "clip" per press
async function readClipboard($: any) {
  const r = await $.process.run(['pbpaste']).catch(() => ({ stdout: '' }))
  const raw = r.stdout.trim()
  if (!raw) return
  await speak($, 'clipboard', 'Clipboard', await spoken($, raw, false), gen, false)
}

// one session owns the inbox (a dir claimed by mkdir, refreshed each poll, taken over after a minute idle);
// files are claimed with an atomic mv, so each is spoken once. Writers create a dotfile and mv it in (see say-inbox.sh).
async function pollInbox($: any) {
  const sid = await $.session.id()
  const script = `o=/tmp/read-aloud-inbox.owner
find "$o" -maxdepth 0 -mmin +1 -exec rm -rf {} \\; 2>/dev/null
find ${INBOX} -type f -mmin +10 -delete 2>/dev/null
mkdir "$o" 2>/dev/null && echo ${sid} > "$o/id"
[ "$(cat "$o/id" 2>/dev/null)" = ${sid} ] || exit 2
touch "$o"
mkdir -p ${INBOX}
for f in ${INBOX}/*; do [ -f "$f" ] || continue; t=/tmp/read-aloud-claim-$$; mv "$f" "$t" 2>/dev/null || continue; cat "$t"; rm -f "$t"; exit 0; done
exit 1`
  for (;;) {
    const r = await $.process.run(['sh', '-c', script]).catch(() => ({ exitCode: 2, stdout: '' }))
    if (r.exitCode === 0 && r.stdout.trim()) {
      // an item may start with "@name: Thread title" (the cloud relay does), which is then read out first
      const named = r.stdout.match(/^@name:\s*(.+)\n/)
      const body = named ? r.stdout.slice(named[0].length) : r.stdout
      await speak($, 'inbox', named ? named[1].trim() : 'Main chat', await spoken($, body, false), gen, !!named)
    }
    await $.clock.sleep(r.exitCode === 2 ? 30000 : 2000)
  }
}

async function bindSession($: any) {
  if (myId && CONTROL) await bridge($, 'remove', myId, instance).catch(() => {})
  gen++; activeTurn = ''; lastAnswer = ''; pending = []; choices = []; cur = 'idle'; commandBusy = false
  myId = await $.session.id()
  instance = 'i-' + String(await $.clock.now()) + '-' + String(Math.random()).slice(2)
  startedAt = await $.clock.now()
  const home = await $.env.get('HOME')
  if (!home) throw new Error('HOME is required for private conversation state')
  CONTROL = home + '/.cache/read-aloud/conversation'
  cwd = await $.session.cwd()
  await findLocal($)
  await loadSettings($)
  connected = true
  await publish($)
}

export const register: Register = on => {
  let on_ = true // ponytail: toggle via /readaloud, per reload
  on('session.start', async ($, e, next) => {
    $.command.register({ name: 'readaloud', description: 'Toggle speaking replies aloud' })
    $.command.register({ name: 'cadence', description: 'Toggle natural spoken rewrite' })
    await bindSession($)
    await ensureBar($)
    $.clock.every(400, () => { pollControl($) })
    $.clock.every(2000, () => {
      publish($).catch(error => $.ui.log(String(error), { to: 'debug' }))
      if (speaking || cur === 'queued') controllerAlive($).then(alive => { if (!alive) stopNow($, true) }).catch(() => {})   // quitting the app stops reading
    })
    $.clock.every(30000, () => { findLocal($).then(() => publish($)).catch(() => {}) })
    watchKeys($).catch(error => $.ui.log(String(error), { to: 'debug' }))
    pollInbox($).catch(error => $.ui.log(String(error), { to: 'debug' }))
    return next(e)
  })
  on('session.end', async ($, e, next) => {
    connected = false; gen++
    await bridge($, 'remove', myId, instance).catch(() => {})
    return next(e)
  })
  on('classic.SessionStart', async ($, e, next) => {
    if (CONTROL && (e.source === 'clear' || e.source === 'resume')) await bindSession($)
    return next(e)
  })
  on('turn.start', async ($, e, next) => {
    if (!e.agentId) { activeTurn = e.turnId; await publish($) }
    return next(e)
  })
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    await loadSettings($)
    if (!settings.voice || e.agentId || !(await controllerAlive($))) return next(e)
    const answers: Record<string, string> = {}
    for (const question of e.questions) {
      const request = { id: instance + '-q' + (++requestCount), kind: 'question', question: question.question,
        options: (question.options ?? []).map((option: any) => option.label), multiSelect: question.multiSelect }
      answers[question.question] = await waitForAnswer($, request)
    }
    return { result: { questions: e.questions, answers } }
  }).catch(($, e, next) => ({ deny: 'Voice question was cancelled or timed out. Please ask again.' }))
  on('classic.PermissionRequest', async ($, e, next) => {
    const decision = await next(e)
    if (decision.decision) return decision
    await loadSettings($)
    if (!settings.voice || !(await controllerAlive($))) return decision
    const request = { id: instance + '-p' + (++requestCount), kind: 'permission', tool: e.tool_name,
      question: 'Allow this action once?', detail: JSON.stringify(e.tool_input) }
    const answer = await waitForAnswer($, request)
    return { ...decision, decision: answer === 'approve action' ? { behavior: 'allow' as const } : { behavior: 'deny' as const, message: 'Action declined in voice controller' } }
  }).catch(($, e, next) => ({ decision: { behavior: 'deny' as const, message: 'Voice approval cancelled or timed out' } }))
  on('command.run', { command: 'cadence' }, async ($, e) => {
    cadence = !cadence
    await writeSetting($, 'rewrite', cadence)
    return { text: `cadence ${cadence ? 'on' : 'off'}` }
  }).catch(($, e, next) => next(e))
  on('command.run', { command: 'readaloud' }, ($, e) => {
    on_ = !on_
    return { text: `read-aloud ${on_ ? 'on' : 'off'}` }
  })

  // a new prompt ends whatever is still being read
  on('prompt.submit', async ($, e, next) => {
    choices = []
    await stopNow($)
    return next(e)
  })

  // controls above the prompt while this session's item is queued or being read
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const p = await read($, phase)
    if (e.props.hasSurvey || p === 'idle') return next(e)
    const name = await read($, who)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box>
        <Text>{p === 'queued' ? (settings.manual ? 'Ready to read aloud ' : 'Queued to read aloud ') : p === 'paused' ? `Paused: ${name} ` : `Reading: ${name} `}</Text>
        {p === 'queued' && settings.manual && <Button key="play" label="Read now" onPress={() => { approved = true }} />}
        {p !== 'queued' && <Button key="pause" label={p === 'paused' ? 'Resume' : 'Pause'} onPress={() => togglePause($)} />}
        <Button key="stop" label="Stop" onPress={() => stopNow($, true)} />
      </Box>
    )
  })

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId) return r
    if (activeTurn === e.turnId) activeTurn = ''
    if (!e.isAborted && e.answer) { lastAnswer = e.answer; choices = findChoices(e.answer) }
    await publish($)
    if (!on_ || e.isAborted || !e.answer) return r
    const off = await $.process.run(['sh', '-c', 'test -e "$HOME/.claude/read-aloud-off" || test "$BRAIN_HEADLESS" = 1']).then((x: any) => x.exitCode === 0, () => false)
    if (off) return r
    await loadSettings($)
    // Conversation mode lets other sessions wait visibly without taking over the audio.
    if (settings.voice && !(await selected($))) return r
    const mine = ++gen
    live = false
    const raw = e.answer
    spoken($, raw, true).then(async text => {
      if (gen === mine && (!settings.voice || await selected($)))
        await speak($, 'reply', displayName(), text, mine, true)
    }).catch(error => $.ui.log(String(error), { to: 'debug' }))
    return r
  })
}
