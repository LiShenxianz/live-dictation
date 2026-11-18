const fs = require('node:fs');
const path = require('node:path');
const sherpa = require('./node_modules/sherpa-onnx-node');
const model = path.join(__dirname, 'model');
const weight = name => {
  const filename = path.join(model, name);
  fs.accessSync(filename, fs.constants.R_OK);
  return filename;
};
const recognizer = new sherpa.OnlineRecognizer({
  featConfig: { sampleRate: 16000, featureDim: 80 },
  modelConfig: {
    transducer: { encoder: weight('encoder.int8.onnx'), decoder: weight('decoder.onnx'), joiner: weight('joiner.int8.onnx') },
    tokens: weight('tokens.txt'), modelType: 'zipformer2', numThreads: 2, provider: 'cpu',
  },
  decodingMethod: 'greedy_search', enableEndpoint: 1,
  rule1MinTrailingSilence: 2.4, rule2MinTrailingSilence: 1.2, rule3MinUtteranceLength: 20,
});
const stream = recognizer.createStream();
const pieces = [];
function decode() {
  while (recognizer.isReady(stream)) recognizer.decode(stream);
}
function text() {
  const current = recognizer.getResult(stream).text.trim();
  return [...pieces, current].filter(Boolean).join(' ').replace(/(?<=[\p{Script=Han}，。！？])\s+(?=[\p{Script=Han}，。！？])/gu, '');
}
let previous = '';
function feed(samples, live) {
  for (let i = 0; i < samples.length; i += 7680) {
    stream.acceptWaveform({ samples: samples.subarray(i, i + 7680), sampleRate: 16000 });
    decode();
    if (live) {
      const current = text();
      if (current !== previous) {
        previous = current;
        console.log(JSON.stringify({partial: current}));
      }
    }
    if (recognizer.isEndpoint(stream)) {
      const part = recognizer.getResult(stream).text.trim();
      if (part) pieces.push(part);
      recognizer.reset(stream);
    }
  }
}
function finish() {
  stream.acceptWaveform({ samples: new Float32Array(16000), sampleRate: 16000 });
  stream.inputFinished();
  decode();
  return text();
}
if (process.argv[2] === '--live') {
  let remainder = Buffer.alloc(0);
  process.stdin.on('data', chunk => {
    const bytes = remainder.length ? Buffer.concat([remainder, chunk]) : chunk;
    const count = Math.floor(bytes.length / 2);
    const samples = new Float32Array(count);
    for (let i = 0; i < count; i++) samples[i] = bytes.readInt16LE(i * 2) / 32768;
    remainder = bytes.subarray(count * 2);
    feed(samples, true);
  });
  process.stdin.on('end', () => console.log(JSON.stringify({final: finish()})));
} else {
  const wav = sherpa.readWave(process.argv[2]);
  if (wav.sampleRate !== 16000) throw new Error('录音需要 16 kHz 单声道 PCM。');
  feed(wav.samples, false);
  process.stdout.write(finish());
}
