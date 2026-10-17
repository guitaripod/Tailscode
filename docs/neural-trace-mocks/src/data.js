const BUILD_FIX=[
 {fam:'think',tool:'Thinking',status:'ok',msg:1,at:'14:02:11',text:'The Linux build stops in TranscriptRows: a Compaction case reached the switch and nothing answers it. Look at every site that switches over the part kind before touching anything.'},
 {fam:'sense',tool:'Grep',status:'ok',msg:2,at:'14:02:19',arg:'case .compaction  TailscodeLinux/Sources',out:['TailscodeLinux/Sources/Chat/TranscriptRows.swift:212','TailscodeLinux/Sources/Chat/RowFactory.swift:88']},
 {fam:'sense',tool:'Read',status:'ok',msg:2,at:'14:02:19',arg:'TailscodeLinux/Sources/Chat/TranscriptRows.swift',key:'TranscriptRows.swift',out:['204 lines','switch part.kind { case .text, .reasoning, .tool, .file, .compaction …']},
 {fam:'sense',tool:'Read',status:'ok',msg:2,at:'14:02:19',arg:'TailscodeLinux/Sources/Parity.swift',out:['388 lines','case .compactActivity: return .implemented("CompactionCell")']},
 {fam:'act',tool:'Edit',status:'ok',msg:3,at:'14:02:40',arg:'TailscodeLinux/Sources/Chat/TranscriptRows.swift',key:'TranscriptRows.swift',diff:[6,1],out:['The file TranscriptRows.swift has been updated.']},
 {fam:'shell',tool:'Bash',status:'fail',msg:4,at:'14:02:52',arg:'swift build -c release 2>&1 | tail -20',key:'swift build',keyKind:'cmd',out:['TranscriptRows.swift:212: error: switch must be exhaustive','  note: add missing case: .note(_)']},
 {fam:'think',tool:'Thinking',status:'ok',msg:5,at:'14:03:30',text:'The build names .note, which my first edit did not cover. The Mac client answers the same capability in its own manifest, so check it while the cause is fresh.'},
 {fam:'sense',tool:'Read',status:'ok',msg:6,at:'14:03:36',arg:'TailscodeMac/Sources/Parity.swift',key:'Mac Parity.swift',out:['412 lines','case .compactActivity: return .implemented("CompactionCell")']},
 {fam:'act',tool:'Edit',status:'ok',msg:7,at:'14:03:58',arg:'TailscodeMac/Sources/Parity.swift',key:'Mac Parity.swift',diff:[3,0],out:['The file Parity.swift has been updated.']},
 {fam:'act',tool:'Edit',status:'ok',msg:8,at:'14:04:10',arg:'TailscodeLinux/Sources/Chat/TranscriptRows.swift',key:'TranscriptRows.swift',diff:[2,2],out:['The file TranscriptRows.swift has been updated.']},
 {fam:'shell',tool:'Bash',status:'ok',msg:9,at:'14:07:46',arg:'swift build -c release 2>&1 | tail -20',key:'swift build',keyKind:'cmd',recovered:true,out:['Compiling TailscodeLinux','Build complete! (212.4s)']},
 {fam:'shell',tool:'Bash',status:'ok',msg:10,at:'14:07:58',arg:'scripts/parity.sh --check',out:['parity: 3 clients · 41 capabilities · 0 gaps']},
 {fam:'delegate',tool:'Task',status:'ok',msg:11,at:'14:08:05',arg:'Review the diff for any switch over MessagePart.Kind that is still not exhaustive',spawn:'reviewer · 7 tools · expands in place',out:['No other switch is affected.']},
 {fam:'shell',tool:'Bash',status:'ok',msg:12,at:'14:08:40',arg:'scripts/install-linuxapp.sh',out:['Installed Tailscode 1.79','restarted pid 41872']}
];
BUILD_FIX[5].recovered=true;

const DEMO_RUNS={
 r1:[
  {fam:'shell',tool:'Bash',status:'ok',msg:1,arg:'ls ~/Dev/film/tailscode-everywhere',out:['README.md  cut.sh  broll/  remotion/  sync/']},
  {fam:'shell',tool:'Bash',status:'ok',msg:2,arg:'ffprobe -v error -show_entries format=duration -of csv=p=0 …/203-pantera-walk.flac',out:['336.12']},
  {fam:'shell',tool:'Bash',status:'ok',msg:3,arg:'sed -n 1,60p scripts/film.sh',out:['#!/usr/bin/env bash','set -euo pipefail']},
  {fam:'shell',tool:'Bash',status:'ok',msg:4,arg:'rg -n "demo" scripts/dev-linuxapp.sh scripts/run-mac.sh',out:['scripts/run-mac.sh:41:  --demo → scripted conversation']},
  {fam:'shell',tool:'Bash',status:'ok',msg:5,arg:'scripts/dev-linuxapp.sh status',out:['running · rss 412 MB · windows 1']},
  {fam:'shell',tool:'Bash',status:'ok',msg:6,arg:'ls ~/Dev/film/tailscode-everywhere/broll | head',out:['walk-01.mp4  walk-02.mp4  ltx-a.mp4']}
 ],
 r2:[
  {fam:'shell',tool:'Bash',status:'ok',msg:1,arg:'ffmpeg -i …/203-pantera-walk.flac -af astats -f null -',out:['Overall RMS −14.2 dB']},
  {fam:'shell',tool:'Bash',status:'ok',msg:2,arg:'python3 scripts/beats.py …/203-pantera-walk.flac',out:['tempo 115.0 (half-time 57.5)','first riff onset 8.75 s']},
  {fam:'shell',tool:'Bash',status:'ok',msg:3,arg:'python3 scripts/beats.py --grid 8.75 --bars 16',out:['16 bars → 33.4 s']},
  {fam:'shell',tool:'Bash',status:'ok',msg:4,arg:'mkdir -p out/demo && ls out/demo',out:['(empty)']},
  {fam:'shell',tool:'Bash',status:'ok',msg:5,arg:'scripts/dev-linuxapp.sh start --release --drive demo.drive',out:['started pid 38214 on :9']},
  {fam:'shell',tool:'Bash',status:'ok',msg:6,arg:'scripts/dev-linuxapp.sh shot out/demo/01.png',out:['out/demo/01.png 3840×2160']},
  {fam:'shell',tool:'Bash',status:'ok',msg:7,arg:"scripts/dev-linuxapp.sh drive '2000:open=1;4000:splits'",out:['ok']}
 ],
 r3:[
  {fam:'shell',tool:'Bash',status:'ok',msg:1,arg:'scripts/install-linuxapp.sh',out:['compiling TailscodeLinux 212 s','Installed Tailscode 1.79']},
  {fam:'sense',tool:'Read',status:'ok',msg:2,arg:'docs/marketing-2026-10.md',out:['## Preview video','60 s, beat-synced']},
  {fam:'delegate',tool:'Skill',status:'ok',msg:3,arg:'frames-cli',out:['Launching skill: frames-cli']},
  {fam:'sense',tool:'Read',status:'ok',msg:4,arg:'scripts/film.sh',out:['204 lines']},
  {fam:'shell',tool:'Bash',status:'ok',msg:5,arg:'frames doctor',out:['frames 0.9.2 · bezels ok']},
  {fam:'shell',tool:'Bash',status:'ok',msg:6,arg:'ffprobe -v error -show_streams ios-tour/walk.mov',out:['codec hevc · 2622×1206 · 60 fps']}
 ],
 r4:[
  {fam:'think',tool:'Thinking',status:'ok',msg:1,text:'The iOS tour footage is 60 fps and the Linux capture is 30. Resample the tour once, then cut both to the riff at 8.75 s.'},
  {fam:'sense',tool:'Read',status:'ok',msg:2,arg:'out/demo/cut-list.json',out:['{ "riff": 8.75, "cuts": 22 }']},
  {fam:'shell',tool:'Bash',status:'run',msg:3,arg:'ffmpeg -i ios-tour/walk.mov -vf fps=30 -c:v libx264 out/demo/ios-30.mp4',out:['frame= 412 fps=96 time=00:00:13.7']}
 ]
};

const TURN=(function(){
  const FLAC='/mnt/nvme8tb/Music/Pantera-…/203-pantera-walk.flac';
  const off=[0,0,9,21,28,36,41,52,70,78,85,96,101,112,331,340,349,357,366,372,380,391,440,449,458,497,505];
  function T(m){const t=14*3600+2*60+11+off[m];const h=Math.floor(t/3600),mi=Math.floor(t%3600/60),se=t%60;return [h,mi,se].map(v=>String(v).padStart(2,'0')).join(':');}
  const s=[];
  function add(m,o){s.push(Object.assign({msg:m,at:T(m),status:'ok'},o));}
  add(1,{fam:'think',tool:'Thinking',text:'He wants a shareable mp4 made with the real apps and mock data over the Pantera track. The film rig already records the Linux app in --demo and cuts the iOS tour, so reuse it instead of building a new one.'});
  add(2,{fam:'shell',tool:'Bash',arg:'ls ~/Dev/film/tailscode-everywhere',out:['README.md  cut.sh  broll/  remotion/  sync/']});
  add(2,{fam:'shell',tool:'Bash',arg:'ffprobe -v error -show_entries format=duration -of csv=p=0 '+FLAC,key:'203-pantera-walk.flac',out:['336.12']});
  add(3,{fam:'shell',tool:'Bash',arg:'sed -n 1,60p scripts/film.sh',key:'film.sh',out:['#!/usr/bin/env bash','set -euo pipefail']});
  add(4,{fam:'shell',tool:'Bash',arg:'rg -n "demo" scripts/dev-linuxapp.sh scripts/run-mac.sh',out:['scripts/run-mac.sh:41:  --demo → scripted conversation']});
  add(5,{fam:'shell',tool:'Bash',arg:'scripts/dev-linuxapp.sh status',out:['running · rss 412 MB · windows 1']});
  add(6,{fam:'say',tool:'Said',text:'Building it from the existing film rig: Linux app in --demo on a private 4K display, plus the iOS demo tour, cut to "Walk".'});
  add(7,{fam:'shell',tool:'Bash',arg:'ffmpeg -i '+FLAC+' -af astats -f null -',key:'203-pantera-walk.flac',out:['Overall RMS −14.2 dB']});
  add(7,{fam:'shell',tool:'Bash',arg:'python3 scripts/beats.py '+FLAC,key:'203-pantera-walk.flac',out:['tempo 115.0 (half-time 57.5)','first riff onset 8.75 s']});
  add(8,{fam:'shell',tool:'Bash',arg:'python3 scripts/beats.py --grid 8.75 --bars 16',out:['16 bars → 33.4 s']});
  add(9,{fam:'shell',tool:'Bash',arg:'scripts/dev-linuxapp.sh start --release --drive demo.drive',out:['started pid 38214 on :9']});
  add(10,{fam:'shell',tool:'Bash',arg:'scripts/dev-linuxapp.sh shot out/demo/01.png',out:['out/demo/01.png 3840×2160']});
  add(11,{fam:'shell',tool:'Bash',arg:"scripts/dev-linuxapp.sh drive '2000:open=1;4000:splits'",out:['ok']});
  add(12,{fam:'say',tool:'Said',text:'Song mapped (~115 BPM half-time, riff hits at 8.75 s); building the Linux release while I check the iOS footage.'});
  add(13,{fam:'shell',tool:'Bash',arg:'scripts/install-linuxapp.sh',out:['compiling TailscodeLinux 212 s','Installed Tailscode 1.79']});
  add(13,{fam:'sense',tool:'Read',arg:'docs/marketing-2026-10.md',out:['## Preview video','60 s, beat-synced']});
  add(14,{fam:'delegate',tool:'Skill',arg:'frames-cli',out:['Launching skill: frames-cli']});
  add(15,{fam:'sense',tool:'Read',arg:'scripts/film.sh',key:'film.sh',out:['204 lines']});
  add(16,{fam:'shell',tool:'Bash',arg:'frames doctor',out:['frames 0.9.2 · bezels ok']});
  add(17,{fam:'shell',tool:'Bash',arg:'ffprobe -v error -show_streams ios-tour/walk.mov',out:['codec hevc · 2622×1206 · 60 fps']});
  add(18,{fam:'think',tool:'Thinking',text:'The iOS tour is 60 fps and the Linux capture is 30. Resample the tour once, then cut both to the riff at 8.75 s.'});
  add(19,{fam:'sense',tool:'Read',arg:'out/demo/cut-list.json',key:'cut-list.json',out:['{ "riff": 8.75, "cuts": 22 }']});
  add(20,{fam:'act',tool:'Edit',arg:'out/demo/cut-list.json',key:'cut-list.json',diff:[4,1],out:['The file cut-list.json has been updated.']});
  add(21,{fam:'shell',tool:'Bash',arg:'ffmpeg -i ios-tour/walk.mov -vf fps=30 -c:v libx264 out/demo/ios-30.mp4',out:['frame= 1260 fps=96 time=00:00:42.0']});
  add(22,{fam:'shell',tool:'Bash',status:'fail',recovered:true,arg:'ffmpeg -f concat -i out/demo/cut-list.txt -i '+FLAC+' -map 1:a -shortest out/demo/tailscode-demo.mp4',key:'ffmpeg mux',keyKind:'cmd',out:["Stream map '1:a' matches no streams."]});
  add(23,{fam:'act',tool:'Edit',arg:'out/demo/cut-list.json',key:'cut-list.json',diff:[1,1],out:['The file cut-list.json has been updated.']});
  add(24,{fam:'shell',tool:'Bash',arg:'ffmpeg -f concat -i out/demo/cut-list.txt -i '+FLAC+' -map 1:a -shortest out/demo/tailscode-demo.mp4',key:'ffmpeg mux',keyKind:'cmd',out:['video:19.4MiB audio:1.4MiB','muxing overhead 0.4%']});
  add(25,{fam:'shell',tool:'Bash',arg:'ffprobe -v error -show_entries format=duration out/demo/tailscode-demo.mp4',out:['62.04']});
  add(26,{fam:'delegate',tool:'Task',arg:'Watch the cut and confirm the first tap lands on the riff at 8.75 s',spawn:'reviewer · 5 tools · expands in place',out:['First tap at 8.74 s. Riff lands on it.']});
  return s;
})();

const TURN_BIG=(function(){
  const out=[];
  for(let c=0;c<6;c++)TURN.forEach(s=>{
    const n=Object.assign({},s,{msg:s.msg+c*30});
    if(c>0){delete n.key;n.at=s.at;}
    out.push(n);
  });
  return out;
})();

const TURN_ANSWER=['Done. The demo is at out/demo/tailscode-demo.mp4: 62 s, 3840×2160 at 30 fps, with Pantera\'s "Walk" playing from the first second to the last.','The first tap in the iOS tour lands exactly on the riff at 8.75 s, and the Linux app plays through its split-pane tour after it. Everything on screen is mock data in the real apps.'];

const SUB=[
 {fam:'think',tool:'Thinking',status:'ok',msg:1,at:'14:10:12',text:'Check the claim against the file itself: find the frame at 8.74 s in the render and see whether the first tap lands on the riff.'},
 {fam:'sense',tool:'Read',status:'ok',msg:2,at:'14:10:14',arg:'out/demo/cut-list.json',key:'cut-list.json',out:['{ "riff": 8.75, "cuts": 22 }']},
 {fam:'sense',tool:'Read',status:'ok',msg:2,at:'14:10:14',arg:'out/demo/beats.json',out:['{ "tempo": 115.0, "onsets": [8.75, …] }']},
 {fam:'shell',tool:'Bash',status:'ok',msg:3,at:'14:10:19',arg:'ffmpeg -ss 8.74 -i out/demo/tailscode-demo.mp4 -frames:v 1 out/demo/check.png',out:['frame=1 size=412kB']},
 {fam:'shell',tool:'Bash',status:'ok',msg:4,at:'14:10:31',arg:'python3 scripts/tap_at.py out/demo/check.png',out:['tap ripple radius 14 px at 8.74 s']}
];
