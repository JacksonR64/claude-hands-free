import { expect, test } from 'claude-code/testing'

function stub(on: any, answer: string, voice = true, fail = false) {
  on('process.run', ($: any, e: any) => {
    const args = e.argv ?? []
    if (args.includes('wait')) {
      if (fail) return { value: { exitCode: 1, stdout: '', stderr: 'timeout' } }
      return { value: { exitCode: 0, stdout: JSON.stringify({ text: answer }), stderr: '' } }
    }
    return { value: { exitCode: 0, stdout: JSON.stringify({ voice, rewrite: false }), stderr: '' } }
  })
  on('fs.read', () => ({ value: '{}' }))
}

test('generic yes cannot approve a tool action', async ($, on) => {
  stub(on, 'yes')
  on('classic.PermissionRequest', () => ({}))
  const result = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'echo demo' } })
  expect(result.decision?.behavior).toBe('deny')
})

test('explicit approval is for this call only, without new permission rules', async ($, on) => {
  stub(on, 'approve action')
  on('classic.PermissionRequest', () => ({}))
  const result = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'echo demo' } })
  expect(result.decision).toEqual({ behavior: 'allow' })
})

test('a prior permission decision remains authoritative', async ($, on) => {
  stub(on, 'approve action')
  on('classic.PermissionRequest', () => ({ decision: { behavior: 'deny', message: 'policy' } }))
  const result = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'echo demo' } })
  expect(result.decision).toEqual({ behavior: 'deny', message: 'policy' })
})

test('a failed voice bridge denies the action', async ($, on) => {
  stub(on, 'approve action', true, true)
  on('classic.PermissionRequest', () => ({}))
  const result = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'echo demo' } })
  expect(result.decision?.behavior).toBe('deny')
})

test('voice disabled preserves the host permission flow', async ($, on) => {
  stub(on, '', false)
  on('classic.PermissionRequest', () => ({}))
  const result = await $.classic.PermissionRequest({ tool_name: 'Bash', tool_input: { command: 'echo demo' } })
  expect(result).toEqual({})
})

test('question answer returns through the actual tool result', async ($, on) => {
  stub(on, 'Grey patches')
  const result = await $.tool.call({ tool: 'AskUserQuestion', questions: [{ question: 'Which calibration?', header: 'Calibration', options: [{ label: 'Grey patches', description: '' }, { label: 'Clear to black', description: '' }], multiSelect: false }] })
  expect(result.result.answers).toEqual({ 'Which calibration?': 'Grey patches' })
})
