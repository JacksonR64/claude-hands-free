import { expect, mock, test } from 'claude-code/testing'

test('session stays registered while idle and routes messages to its own instance', async ($, on) => {
  const clock = mock.clock(on, { now: 1800000000000 })
  mock.env(on, { HOME: '/test-home' })
  const published: any[] = []
  const receipts: any[] = []
  const prompts: any[] = []
  let nextCommands: any[] = []
  let currentID = 'session-a'
  let title = 'Test session'
  on('session.id', () => ({ value: currentID }))
  on('classic.SessionStart', () => ({}))
  on('session.cwd', () => ({ value: '/test-project' }))
  on('command.register', () => ({ value: {} }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.start', () => ({}))
  on('fs.read', () => ({ value: '{}' }))
  on('process.spawn', async function* () { return { deny: 'No native processes in tests' } })
  on('ui.log', () => ({ value: undefined }))
  on('process.run', ($, e) => {
    const args = e.argv
    let stdout = ''
    if (args[0] === 'python3' && args[1].endsWith('/bridge.py')) {
      if (args[2] === 'publish') published.push(JSON.parse(args[3]))
      if (args[2] === 'ack') receipts.push({ command: JSON.parse(args[3]), status: args[4] })
      if (args[2] === 'drain') { stdout = JSON.stringify(nextCommands); nextCommands = [] }
    } else if (args[0] === 'python3' && args[1].endsWith('/session-info.py')) stdout = JSON.stringify({ title, local: 'local-test' })
    else if (args[0] === 'sh' && args.includes('-c') && args.join(' ').includes('settings.json')) stdout = JSON.stringify({ voice: false, rewrite: false })
    return { value: { exitCode: 0, stdout, stderr: '' } }
  })
  on('prompt.submit', ($, e) => { prompts.push(e); return { text: e.text } })
  await $.session.start({ cwd: '/test-project', surface: 'terminal', isInteractive: true })
  await clock.settle()
  expect(published[0].phase).toBe('idle')
  expect(published[0].name).toBe('Test session')
  expect(published[0].id).toBe('session-a')
  const instance = published[0].instance
  nextCommands = [{ id: 'message-1', session: 'session-a', instance, verb: 'reply', text: 'Please review this', ts: clock.now() }]
  await clock.advance(400)
  await clock.settle()
  expect(prompts).toHaveLength(1)
  expect(prompts[0].text).toBe('Please review this')
  expect(prompts[0].origin.asUser).toBe(true)
  expect(receipts.map(value => value.status)).toEqual(['queued', 'started'])
  await clock.advance(2000)
  expect(published[published.length - 1].phase).toBe('idle')
  currentID = 'session-b'; title = ''
  await $.classic.SessionStart({ source: 'clear' })
  expect(published[published.length - 1].id).toBe('session-b')
  expect(published[published.length - 1].name).toBe('test-project')
  expect(published[published.length - 1].instance).not.toBe(instance)
})
