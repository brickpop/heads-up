// Renders the app icon, Resources/AppIcon.icns, from the SVG source in Resources/Icons/source/.
// Run it through tools/make-icons.sh, which provides @resvg/resvg-js.
// Usage: node tools/make-icons.js <source folder> <output folder>
'use strict';
const {Resvg}=require('@resvg/resvg-js');const fs=require('fs');const path=require('path');
const [,,src,out]=process.argv;
const png=(f,w)=>new Resvg(fs.readFileSync(f),{fitTo:{mode:'width',value:w}}).render().asPng();
// App icon: .icns with PNG entries
const a=path.join(src,'AppIcon-Light.svg');
const types=[['icp4',16],['icp5',32],['ic11',32],['ic12',64],['ic07',128],['ic13',256],['ic08',256],['ic14',512],['ic09',512],['ic10',1024]];
const parts=types.map(([t,w])=>{const d=png(a,w);const h=Buffer.alloc(8);h.write(t,0,'ascii');h.writeUInt32BE(d.length+8,4);return Buffer.concat([h,d]);});
const body=Buffer.concat(parts);const head=Buffer.alloc(8);head.write('icns',0,'ascii');head.writeUInt32BE(body.length+8,4);
fs.writeFileSync(path.join(out,'AppIcon.icns'),Buffer.concat([head,body]));
