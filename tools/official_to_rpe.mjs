// official（Phigros 原生 v3）→ RPE 谱面转换器。
// "以 rpe-next 为准"落到字面上就是：**不自己重写一遍换算**，直接跑 rpe-next 自己的
// parseOfficialChart + serializeChart。它一个文件里同时定了线/音符/事件/噪域四套换算，
// 我们抄哪一套都会有抄错的风险，跑它的代码没有。
//
// 跑法：node tools/official_to_rpe.mjs <官谱.json> <输出.json> <rpe-next/src/core>
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [inFile, outFile, srcDir] = process.argv.slice(2);
if (!inFile || !outFile || !srcDir) {
  console.error('用法: node tools/official_to_rpe.mjs <官谱.json> <输出.json> <rpe-next/src/core>');
  process.exit(2);
}
const imp = f => import(pathToFileURL(path.join(srcDir, f)).href);
const { parseOfficialChart } = await imp('official-chart.mjs');
const { serializeChart } = await imp('chart.mjs');

const raw = JSON.parse(fs.readFileSync(inFile, 'utf8'));
// rpe-next 的转换器末尾自带校验，官谱里 appearTime 比 disappearTime 晚零点几毫秒的条目
// （IN 谱 i=148：28.3 vs 28.2993）会让它直接抛错 —— 也就是它其实吃不下这份真谱。
// 这里先把源数据钳平再交给它，并如实报数；这是上游的 bug，值得回一条 issue。
let fixed = 0;
for (const e of raw.blockAreaList ?? []) {
  if (e.appearTime > e.disappearTime) { e.disappearTime = e.appearTime; fixed++; }
  if (e.enableTime > e.disableTime) { e.disableTime = e.enableTime; fixed++; }
}
const chart = parseOfficialChart(raw);
const lines = chart.judgeLineList.length;
const notes = chart.judgeLineList.reduce((a, l) => a + (l.notes?.length ?? 0), 0);
const areas = chart.blockAreaList?.length ?? 0;
fs.mkdirSync(path.dirname(path.resolve(outFile)), { recursive: true });
fs.writeFileSync(outFile, serializeChart(chart, { compact: true }));
console.log('O2R ' + path.basename(inFile) + (fixed ? ' 钳平倒挂生命周期=' + fixed : '') + ' → ' + path.basename(outFile)
  + ' 线=' + lines + ' 音符=' + notes + ' 噪域=' + areas
  + ' RPEVersion=' + chart.META.RPEVersion + ' BPM=' + chart.BPMList[0].bpm
  + ' offset=' + chart.META.offset + 'ms');
