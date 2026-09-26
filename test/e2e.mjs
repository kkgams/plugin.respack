import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { respack } from '../build/jco/plugin.respack.js'

const schema = readFileSync(new URL('../src/example.respack.json', import.meta.url), 'utf8')
const slots = readFileSync(new URL('../src/testdata/example.slots.json', import.meta.url), 'utf8')
const odin = respack.generateOdin(schema)
assert.match(odin, /read_slot_0_atlas/)
const packed = respack.build(schema, slots)
assert.ok(packed instanceof Uint8Array)
assert.equal(new TextDecoder().decode(packed.subarray(0, 4)), 'RSPK')
assert.equal(packed[4] | (packed[5] << 8), 1)
assert.equal(packed[6] | (packed[7] << 8), 4)
const invalid = schema.replace('"len": 16', '"len": "16"')
assert.throws(() => respack.generateOdin(invalid), /array len must be non-negative integer/)
console.log('plugin.respack standalone component test: ok')
