// Regenerate native branding from the canonical SVG. Requires Node.js and sharp.
// Run from the repository root: node tool/generate_branding.cjs
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require('sharp');

async function main() {
  const svg = await fs.readFile('assets/logo-icon.svg');
  const outputs = [];
  const ios = 'ios/Runner/Assets.xcassets';
  const catalog = JSON.parse(await fs.readFile(`${ios}/AppIcon.appiconset/Contents.json`));
  for (const image of catalog.images) {
    const size = Number(image.size.split('x')[0]) * Number(image.scale.replace('x', ''));
    outputs.push([`${ios}/AppIcon.appiconset/${image.filename}`, size, true]);
  }
  for (const [suffix, scale] of [['', 1], ['@2x', 2], ['@3x', 3]]) {
    outputs.push([`${ios}/LaunchImage.imageset/LaunchImage${suffix}.png`, 96 * scale, false]);
  }
  for (const [density, scale] of [['mdpi', 1], ['hdpi', 1.5], ['xhdpi', 2], ['xxhdpi', 3], ['xxxhdpi', 4]]) {
    const root = 'android/app/src/main/res';
    outputs.push([`${root}/mipmap-${density}/ic_launcher.png`, 48 * scale, true]);
    outputs.push([`${root}/drawable-${density}/launch_image.png`, 96 * scale, false]);
  }
  for (const [file, size, opaque] of outputs) {
    await fs.mkdir(path.dirname(file), {recursive: true});
    let render = sharp(svg, {density: 768}).resize(size, size);
    if (opaque) render = render.flatten({background: '#09090b'});
    await render.png().toFile(file);
  }
  console.log(`Generated ${outputs.length} native branding assets.`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
