// 差分测试的预言机：用 rpe-next **自己的** noise-areas.mjs / official-noise.mjs 把官谱
// IN.json 的 blockAreaList 转成 RPEVersion>=220 的 schema，产出两样东西：
//   1) IN-rpenext.json —— 一份只带噪域的 RPE 谱，喂给 PTN 的 ChartPlayer；
//   2) expect.json     —— 同一批时刻上，rpe-next 自己算出的四角（绝对单位，y 向上）。
// 跑法：node tools/rpenext_oracle.mjs <rpe-next-src目录> <IN.json> <输出目录>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [srcDir, inFile, outDir] = process.argv.slice(2);
const { convertOfficialNoiseAreas } = await import(pathToFileURL(path.join(srcDir, 'official-noise.mjs')).href);
const { noiseRuntime, normalizeNoiseAreas } = await import(pathToFileURL(path.join(srcDir, 'noise-areas.mjs')).href);
const { beatValue } = await import(pathToFileURL(path.join(srcDir, 'beat.mjs')).href);

const raw = JSON.parse(fs.readFileSync(inFile, 'utf8'));
// 官谱本身有 appearTime 比 disappearTime 晚零点几毫秒的条目（IN 谱 i=148：28.3 vs 28.2993），
// rpe-next 的转换器末尾自带校验、直接抛错。先把**源数据**钳平，再让 rpe-next 转换，
// 这样预言机仍然是它本尊，测的也只有几何。
let clamped = 0;
for (const e of raw.blockAreaList) {
  if (e.appearTime > e.disappearTime) { e.disappearTime = e.appearTime; clamped++; }
  if (e.enableTime > e.disableTime) { e.disableTime = e.enableTime; clamped++; }
}
let areas = convertOfficialNoiseAreas(raw.blockAreaList, 60, 0);
areas = normalizeNoiseAreas(areas);

// tempo：rpe-next 的 tempo.seconds(beat) 要自己给一个，这里按 60bpm 常量对齐 PTN 侧的 BPMList
const tempo = { seconds: b => beatValue(b) }; // BPM=60 ⇒ 拍≡秒，和 PTN 侧同一时间基

const chart = {
  RPEVersion: 220,
  BPMList: [{ startTime: [0, 0, 1], bpm: 60, factor: 1 }],
  META: { RPEVersion: 220, name: 'rpenext-oracle', level: 'IN', offset: 0,
          background: 'bg.png', song: 'song.ogg', charter: 'qa', composer: 'qa' },
  judgeLineGroup: ['1'],
  judgeLineList: [{ Name: 'L0', Texture: 'line.png', anchor: [0.5, 0.5], bpmfactor: 1,
    extended: {}, father: -1, isCover: 1, notes: [], numOfNotes: 0, rotateWithFather: 0,
    zOrder: 0, eventLayers: [{ alphaEvents: [], speedEvents: [], moveXEvents: [], moveYEvents: [], rotateEvents: [] }] }],
  multiLineString: '0 1 3 11', multiScale: 1, name: 'IN-rpenext',
  blockAreaList: areas,
};
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'IN-rpenext.json'), JSON.stringify(chart));

// 采样：每 0.37 秒取一帧（故意不整点，避开"正好落在关键帧上"的巧合命中）
const dur = Math.max(...areas.map(a => beatValue(a.disappearTime)));
const expect = [];
for (let t = 0.37; t < Math.min(dur, 170); t += 0.37) {
  const rows = [];
  for (const a of areas) {
    const rt = noiseRuntime(a, tempo);
    if (t < rt.appear || t >= rt.disappear) continue;
    const s = rt.sample(t);
    rows.push({ name: areas.indexOf(a), state: s.state,
      pts: s.points.map(p => [p.x, p.y]), center: [s.center.x, s.center.y],
      scaleX: s.scaleX, scaleY: s.scaleY, rotation: s.rotation });
  }
  if (rows.length) expect.push({ t, rows });
}
fs.writeFileSync(path.join(outDir, 'expect.json'), JSON.stringify(expect));
console.log('ORACLE areas=' + areas.length + ' 钳掉倒挂生命周期=' + clamped + ' frames=' + expect.length
  + ' livePerFrame=' + Math.round(expect.reduce((a, f) => a + f.rows.length, 0) / Math.max(1, expect.length)));
