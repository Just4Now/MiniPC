const fs = require('fs');
const leaf = fs.readFileSync('D:/MINIPC/tools/signing/app-issued-leaf.cer', 'utf8').trim();
const j = JSON.parse(fs.readFileSync('D:/Agent-MiniPC/gate-a/loop-profile.json', 'utf8'));
j['bundle-info']['development-certificate'] = leaf + '\n';
fs.writeFileSync('D:/Agent-MiniPC/gate-a/loop-profile.json', JSON.stringify(j, null, 2));
console.log('leaf starts', leaf.slice(0, 40), 'bundle', j['bundle-info']['bundle-name']);
