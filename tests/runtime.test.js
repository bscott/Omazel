// Run with: node --test tests/runtime.test.js
// Execute the shipped probe and the service's actual queue/control functions.
const assert = require('node:assert/strict')
const { test } = require('node:test')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vm = require('node:vm')
const { spawnSync } = require('node:child_process')

const root = path.join(__dirname, '..')
const qml = fs.readFileSync(path.join(root, 'Service.qml'), 'utf8')
const model = fs.readFileSync(path.join(root, 'Model.js'), 'utf8').replace(/^\.pragma library\s*$/m, '')

test('contents probes distinguish matches, non-matches, and errors', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'omazel-probe-test-'))
  try {
    const file = path.join(dir, 'large.txt')
    fs.writeFileSync(file, 'Needle\n' + 'padding\n'.repeat(150000))
    const result = spawnSync('bash', [path.join(root, 'scripts/omazel-probe.sh'), file,
      '--grep', 'F', 'literal', 'needle',
      '--grep', 'E', 'regex', '^needle$',
      '--grep', 'F', 'absent', 'not present',
      '--grep', 'E', 'invalid', '['], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    const fields = Object.fromEntries(result.stdout.trim().split('\n').map(line => line.split('\t')))
    assert.equal(fields['probe:literal'], '1')
    assert.equal(fields['probe:regex'], '1')
    assert.equal(fields['probe:absent'], '0')
    assert.equal(fields['probe:invalid'], undefined)
    const context = vm.createContext({})
    vm.runInContext(model, context)
    assert.equal(context.matchCondition({ probes: {} },
      { field: 'contents', op: 'not_contains', probeId: 'invalid' }, 0), false)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

function service() {
  const context = vm.createContext({
    paused: false, pausedFolders: {}, _actQueue: [], _currentPlan: null,
    actProcess: { running: false }, actWatchdog: { restart() {} },
    dryRun: false, activityLog: '/tmp/unused', actScript: '/unused',
    folders: [{ path: '/downloads' }], _cooldown: {}, cooldownSec: 60,
    Model: { planFile() {
      return [plan('/downloads', 'first'), plan('/downloads', 'second')].map(item => {
        delete item.folderPath
        return item
      })
    } }
  })
  for (const name of ['setPaused', 'toggleFolderPause', 'kickAct', 'evaluate', 'alreadyQueued']) {
    const match = qml.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))
    assert.ok(match, name)
    vm.runInContext(match[0], context)
  }
  return context
}

function plan(folderPath, name) {
  return { folderPath, rule: name, ruleId: name, file: folderPath + '/file',
    argv: ['notify', folderPath + '/file', name] }
}

test('global pause holds pending actions after an in-flight action finishes; resume restarts', () => {
  const s = service()
  s.evaluate({}, 0)
  assert.equal(s.actProcess.running, true)
  assert.equal(s._actQueue[0].folderPath, '/downloads')
  s.setPaused(true)
  assert.equal(s.actProcess.running, true, 'allow the in-flight operation to finish')
  s.actProcess.running = false
  s.kickAct()
  assert.equal(s.actProcess.running, false)
  assert.equal(s._actQueue.length, 1)
  s.setPaused(false)
  assert.equal(s.actProcess.running, true)
  assert.equal(s._currentPlan.rule, 'second')
  assert.equal(s._actQueue.length, 0)
})

test('folder pause holds its actions in order while other folders continue', () => {
  const s = service()
  const first = plan('/downloads', 'first')
  // A prior move changes the target, but pause still applies to its origin.
  first.file = '/documents/file'
  first.argv[1] = first.file
  s._actQueue = [first, plan('/downloads', 'second'), plan('/inbox', 'other')]
  s.toggleFolderPause('/downloads')
  s.kickAct()
  assert.equal(s._currentPlan.rule, 'other')
  s.actProcess.running = false
  s.kickAct()
  assert.equal(s.actProcess.running, false)
  assert.equal(s._actQueue.length, 2)
  s.toggleFolderPause('/downloads')
  assert.equal(s._currentPlan.rule, 'first')
  s.actProcess.running = false
  s.kickAct()
  assert.equal(s._currentPlan.rule, 'second')
})
