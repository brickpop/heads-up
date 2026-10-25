// Renders the icon files in Resources/ from the SVG sources in Resources/Icons/source/.
// Run it through tools/make-icons.sh, which provides @resvg/resvg-js.
// Usage: node tools/make-icons.js <source folder> <output folder>
'use strict';
const {Resvg}=require('@resvg/resvg-js');const fs=require('fs');const path=require('path');
const [,,src,out]=process.argv;
const png=(f,w)=>new Resvg(fs.readFileSync(f),{fitTo:{mode:'width',value:w}}).render().asPng();
// Menu bar glyph: PNG @1x/@2x
const g=path.join(src,'MenuBarGlyph.svg');
fs.writeFileSync(path.join(out,'MenuBarGlyph.png'),png(g,18));
fs.writeFileSync(path.join(out,'MenuBarGlyph@2x.png'),png(g,36));
// Menu bar glyph: vector PDF (same geometry as the SVG, y flipped)
const k=1.5188;const f=n=>+n.toFixed(4);
const cs=[
'1.5 w 1 J 1 j 0 G',
'6 13.5 m 9 16.5 l 12 13.5 l S',
`4.5 2.5 m 13.5 2.5 l ${f(13.5+k)} 2.5 16.25 ${f(5.25-k)} 16.25 5.25 c 16.25 8.25 l 16.25 ${f(8.25+k)} ${f(13.5+k)} 11 13.5 11 c 4.5 11 l ${f(4.5-k)} 11 1.75 ${f(8.25+k)} 1.75 8.25 c 1.75 5.25 l 1.75 ${f(5.25-k)} ${f(4.5-k)} 2.5 4.5 2.5 c h S`,
'4.75 6.75 m 9 6.75 l S'].join('\n');
const objs=['<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 18 18] /Contents 4 0 R /Resources << >> >>',
`<< /Length ${Buffer.byteLength(cs)} >>\nstream\n${cs}\nendstream`];
let pdf='%PDF-1.4\n';const off=[];
objs.forEach((o,i)=>{off.push(Buffer.byteLength(pdf));pdf+=`${i+1} 0 obj\n${o}\nendobj\n`;});
const x=Buffer.byteLength(pdf);
pdf+=`xref\n0 ${objs.length+1}\n0000000000 65535 f \n`+off.map(o=>String(o).padStart(10,'0')+' 00000 n \n').join('');
pdf+=`trailer\n<< /Size ${objs.length+1} /Root 1 0 R >>\nstartxref\n${x}\n%%EOF\n`;
fs.writeFileSync(path.join(out,'MenuBarGlyph.pdf'),pdf);
// App icon: .icns with PNG entries
const a=path.join(src,'AppIcon-Light.svg');
const types=[['icp4',16],['icp5',32],['ic11',32],['ic12',64],['ic07',128],['ic13',256],['ic08',256],['ic14',512],['ic09',512],['ic10',1024]];
const parts=types.map(([t,w])=>{const d=png(a,w);const h=Buffer.alloc(8);h.write(t,0,'ascii');h.writeUInt32BE(d.length+8,4);return Buffer.concat([h,d]);});
const body=Buffer.concat(parts);const head=Buffer.alloc(8);head.write('icns',0,'ascii');head.writeUInt32BE(body.length+8,4);
fs.writeFileSync(path.join(out,'AppIcon.icns'),Buffer.concat([head,body]));
