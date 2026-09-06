import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  compareReleaseVersionPrecedence,
  parseReleaseVersion,
  readReleaseSources,
  releaseSourcePaths,
  repositoryRoot,
  unreleasedSectionHasMaterialChanges,
  validateReleaseSources,
  validateReleaseTag,
  validateReleaseVersion,
} from './validate-release-version.mjs'

const activeVersion = '0.7.0-rc.1'
const activeBaseVersion = '0.7.0'
const publishedStableVersion = '0.6.0'
const synchronizedSurfaceCount = 46
const closedPublicReleasePaths = Object.freeze([
  'README.md',
  'NPM_PUBLISH.md',
  'docs/src/data/capabilities.json',
  'docs/src/content/docs/guide/status.md',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/build-from-source.md',
  'docs/src/content/docs/guide/css-compatibility.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'docs/src/app/components/Home.tsx',
  'examples/build-systems/README.md',
  'examples/next-turbopack/README.md',
  'examples/sveltekit/README.md',
  'examples/astro/README.md',
  'examples/nuxt/README.md',
  'examples/parcel/README.md',
])
const closedNoUnreleasedPaths = Object.freeze([
  'README.md',
  'docs/src/data/capabilities.json',
  'docs/src/content/docs/guide/status.md',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'examples/build-systems/README.md',
])
const closedNoUnpublishedPaths = Object.freeze([
  'NPM_PUBLISH.md',
  'docs/src/data/capabilities.json',
  'docs/src/content/docs/guide/status.md',
  'docs/src/content/docs/guide/builder-integrations.md',
  'docs/src/content/docs/guide/css-compatibility.md',
  'docs/src/content/docs/guide/format-compatibility.md',
  'docs/src/content/docs/guide/recovery-cli.md',
  'docs/src/app/components/Features.tsx',
  'docs/src/app/components/GettingStarted.tsx',
  'examples/build-systems/README.md',
])

function cloneSources() {
  return new Map(readReleaseSources())
}

function replace(sources, filename, current, replacement) {
  const source = sources.get(filename)
  const updated = source.replace(current, replacement)
  assert.notEqual(updated, source, `fixture replacement was not found in ${filename}`)
  sources.set(filename, updated)
}

function replaceEvery(sources, filename, current, replacement) {
  const source = sources.get(filename)
  assert.ok(source.includes(current), `fixture replacement was not found in ${filename}`)
  sources.set(filename, source.replaceAll(current, replacement))
}

function mutateJson(sources, filename, mutate) {
  const value = JSON.parse(sources.get(filename))
  mutate(value)
  sources.set(filename, `${JSON.stringify(value, null, 2)}\n`)
}

function injectCopyProbe(sources, filename, value) {
  if (filename.endsWith('.json')) {
    mutateJson(sources, filename, document => { document.closedReleaseCopyProbe = value })
    return
  }
  sources.set(filename, `${sources.get(filename)}\n${value}\n`)
}

function setActiveSourceVersion(sources, version) {
  const previousVersion = sources.get('VERSION').trim()
  const previousBaseVersion = parseReleaseVersion(previousVersion).base
  const baseVersion = parseReleaseVersion(version).base
  sources.set('VERSION', `${version}\n`)

  mutateJson(sources, 'package.json', manifest => { manifest.version = version })
  mutateJson(sources, 'package-lock.json', lock => {
    lock.version = version
    lock.packages[''].version = version
  })
  mutateJson(sources, 'docs/package-lock.json', lock => { lock.packages['..'].version = version })
  mutateJson(sources, 'vscode-extension/package.json', manifest => { manifest.version = baseVersion })
  mutateJson(sources, 'vscode-extension/package-lock.json', lock => {
    lock.version = baseVersion
    lock.packages[''].version = baseVersion
  })
  mutateJson(sources, 'docs/src/data/capabilities.json', metadata => {
    const zigPackage = metadata.capabilities.find(capability => capability.id === 'zig-package')
    const vscode = metadata.capabilities.find(capability => capability.id === 'vscode')
    assert.ok(zigPackage)
    assert.ok(vscode)
    zigPackage.behavior = zigPackage.behavior.replace(
      `Package \`zigcss\` ${previousVersion}`,
      `Package \`zigcss\` ${version}`,
    )
    vscode.behavior = vscode.behavior.replace(
      `current source extension is Marketplace-compatible package version ${previousBaseVersion} mapped to core ${previousVersion}`,
      `current source extension is Marketplace-compatible package version ${baseVersion} mapped to core ${version}`,
    )
  })

  replace(sources, 'build.zig.zon', `.version = "${previousVersion}"`, `.version = "${version}"`)
  const main = sources.get('src/main.zig').replaceAll(previousVersion, version)
  sources.set(
    'src/main.zig',
    parseReleaseVersion(version).prerelease === null
      ? main.replace('experimental release candidate', 'source build')
      : main,
  )
  const audit = sources.get('tests/regressions/audit.zig')
  sources.set('tests/regressions/audit.zig', audit.replaceAll(previousVersion, version))
  for (const filename of ['Dockerfile', 'Dockerfile.docs', 'Dockerfile.release']) {
    replace(sources, filename, `ARG ZIGCSS_VERSION=${previousVersion}`, `ARG ZIGCSS_VERSION=${version}`)
  }
  replace(
    sources,
    'docs/src/content/docs/guide/build-from-source.md',
    `package \`zigcss\` ${previousVersion}`,
    `package \`zigcss\` ${version}`,
  )
  const neovim = sources.get('neovim-config/README.md')
  sources.set('neovim-config/README.md', neovim.replaceAll(`ZigCSS ${previousVersion}`, `ZigCSS ${version}`))
  replace(
    sources,
    'README.md',
    `> **Active source candidate: ${previousVersion} — unpublished.**`,
    `> **Active source candidate: ${version} — unpublished.**`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    `Active source candidate ${previousVersion} is selected`,
    `Active source candidate ${version} is selected`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/builder-integrations.md',
    `The current unpublished ${previousVersion} source checkout has`,
    `The current unpublished ${version} source checkout has`,
  )
  replace(
    sources,
    'docs/src/app/components/GettingStarted.tsx',
    `unpublished ${previousVersion} candidate`,
    `unpublished ${version} candidate`,
  )
  replace(
    sources,
    'docs/src/app/components/Home.tsx',
    `${previousVersion} · unpublished source proofs`,
    `${version} · unpublished source proofs`,
  )
}

function setCandidateReadyPhase(sources) {
  mutateJson(sources, 'release/next-release.json', contract => {
    contract.state = 'candidate-ready'
    contract.candidateReady = true
    for (const gate of contract.gates.slice(0, -1)) {
      gate.state = 'verified'
      if (gate.evidence.length === 0) gate.evidence = [`verified evidence for ${gate.id}`]
    }
  })
  replace(sources, 'README.md', '`candidateReady: false`', '`candidateReady: true`')
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    'Its `candidateReady` interlock remains `false` until all seven pre-tag gates pass',
    'Its `candidateReady` interlock is `true` after all seven pre-tag gates passed',
  )
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    '5 of 8 admission gates now carry recorded evidence',
    '7 of 8 admission gates now carry recorded evidence',
  )
  replace(
    sources,
    'docs/src/app/components/Home.tsx',
    '5/8 admission gates verified',
    '7/8 admission gates verified',
  )
  replace(
    sources,
    'NPM_PUBLISH.md',
    'It is currently `planned` with `candidateReady: false`',
    'It is currently `candidate-ready` with `candidateReady: true`',
  )
  replace(
    sources,
    'CHANGELOG.md',
    `Planned prerelease target \`${activeVersion}\` is selected in \`release/next-release.json\` but remains unpublished with \`candidateReady: false\` until all seven pre-tag gates pass. Published stable identity remains immutable at \`${publishedStableVersion}\`.`,
    `Prerelease target \`${activeVersion}\` is candidate-ready with \`candidateReady: true\` after all seven pre-tag gates passed. Published stable identity remains immutable at \`${publishedStableVersion}\`.`,
  )
}

function setClosedPhase(sources) {
  setCandidateReadyPhase(sources)
  mutateJson(sources, 'release/next-release.json', contract => {
    contract.schemaVersion = 2
    contract.state = 'closed'
    contract.candidateReady = false
    contract.gates.at(-1).state = 'verified'
    contract.gates.at(-1).evidence = ['publication evidence']
    contract.publicationEvidence = { githubPublishedAt: '2026-09-04T12:34:00Z' }
  })

  // README: close every candidate-delivery claim while retaining unrelated
  // unpublished benchmark and separately unauthorized editor surfaces.
  replace(
    sources,
    'README.md',
    `Active source candidate \`${activeVersion}\` is unpublished.`,
    `ZigCSS \`${activeVersion}\` is the published prerelease on npm \`next\`.`,
  )
  replace(
    sources,
    'README.md',
    `> **Active source candidate: ${activeVersion} — unpublished.**`,
    `> **Published prerelease: ${activeVersion} — npm \`next\`.**`,
  )
  replace(
    sources,
    'README.md',
    '`candidateReady: true`',
    '`candidateReady: false` after immutable publication',
  )
  replace(
    sources,
    'README.md',
    'Historical npm version `0.6.0-rc.2` remains on `next`.',
    `Historical npm version \`0.6.0-rc.2\` remains preserved by its immutable exact version.\n\nnpm \`next\` serves \`zigcss@${activeVersion}\`.`,
  )
  replace(
    sources,
    'README.md',
    'GitHub prerelease and npm `next` publication are verified;',
    'The historical GitHub prerelease and npm publication are verified;',
  )
  replace(
    sources,
    'README.md',
    'it still is not registry delivery until matching native archives pass the release gates.',
    'the published prerelease delivery is bound to its matching verified native archives.',
  )
  replace(
    sources,
    'README.md',
    `The unpublished \`${activeVersion}\` package contract adds`,
    `The published \`${activeVersion}\` prerelease package contract adds`,
  )
  replace(
    sources,
    'README.md',
    'No published npm version currently exposes this new recovery command or integrity inventory.',
    `Published \`zigcss@${activeVersion}\` exposes this recovery command and integrity inventory on npm \`next\`.`,
  )
  replace(
    sources,
    'README.md',
    `The remaining CLI examples describe the current unpublished \`${activeVersion}\` source candidate`,
    `The remaining CLI examples describe the published \`${activeVersion}\` prerelease and current source checkout`,
  )
  replace(
    sources,
    'README.md',
    'The current `Unreleased` source package also exports',
    `The published \`${activeVersion}\` prerelease package exports`,
  )
  replaceEvery(
    sources,
    'README.md',
    `Its active identity is unpublished candidate \`${activeVersion}\`.`,
    `Its published prerelease identity is \`zigcss@${activeVersion}\` on npm \`next\`.`,
  )
  replace(
    sources,
    'README.md',
    'The current `Unreleased` source package adds explicit, typed adapter subpaths',
    `The published \`${activeVersion}\` prerelease package adds explicit, typed adapter subpaths`,
  )
  replace(
    sources,
    'README.md',
    `The adapters are part of the unpublished \`${activeVersion}\` source candidate`,
    `The adapters ship in the published \`${activeVersion}\` prerelease`,
  )

  // Primary status and site components.
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    `Active source candidate ${activeVersion} is selected in \`release/next-release.json\` but is not published.`,
    `ZigCSS ${activeVersion} is the published prerelease on npm \`next\`.`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    'Its `candidateReady` interlock is `true` after all seven pre-tag gates passed',
    'Its `candidateReady` interlock is `false` after immutable publication',
  )
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    '7 of 8 admission gates now carry recorded evidence',
    '8 of 8 admission gates now carry recorded evidence',
  )
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    'immutable npm `latest` version with SLSA provenance, preserved `next`, and anonymous five-syntax install',
    'immutable npm `latest` version with SLSA provenance and anonymous five-syntax install',
  )
  replace(
    sources,
    'docs/src/app/components/Home.tsx',
    `${activeVersion} · unpublished source proofs`,
    `${activeVersion} · published prerelease · npm next`,
  )
  replace(
    sources,
    'docs/src/app/components/Home.tsx',
    '7/8 admission gates verified',
    '8/8 admission gates verified',
  )
  replace(
    sources,
    'docs/src/app/components/GettingStarted.tsx',
    `Its active identity is the unpublished ${activeVersion} candidate.`,
    `ZigCSS ${activeVersion} is published on npm next; stable latest remains ${publishedStableVersion}.`,
  )
  replace(
    sources,
    'docs/src/app/components/GettingStarted.tsx',
    'current Unreleased Node API',
    `published ${activeVersion} prerelease Node API`,
  )
  replace(
    sources,
    'docs/src/app/components/Features.tsx',
    `That evidence belongs to unpublished candidate ${activeVersion}.`,
    `That evidence ships in published prerelease ${activeVersion} on npm next.`,
  )
  replace(
    sources,
    'docs/src/app/components/Features.tsx',
    'rows whose contract says current, source-checkout, or Unreleased remain Unreleased even after their gates pass.',
    'rows labeled current or source-checkout can describe maintained repository proofs alongside the published prerelease.',
  )
  replace(
    sources,
    'docs/src/content/docs/guide/builder-integrations.md',
    `The current unpublished ${activeVersion} source checkout has`,
    `The published ${activeVersion} prerelease and current source checkout have`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/builder-integrations.md',
    'These are `Unreleased` source\ncapabilities:',
    `These capabilities ship in the published \`zigcss@${activeVersion}\` prerelease; the maintained checkout proofs remain stricter than registry installation:`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/builder-integrations.md',
    'only in the current `Unreleased` checkout',
    `in the published ${activeVersion} prerelease and current checkout`,
  )

  // The machine capability inventory and generated status table must advance
  // together so the public status page cannot retain an Unreleased row.
  mutateJson(sources, 'docs/src/data/capabilities.json', metadata => {
    const byId = new Map(metadata.capabilities.map(capability => [capability.id, capability]))
    const nodeApi = byId.get('node-api')
    const zigPackage = metadata.capabilities.find(capability => capability.id === 'zig-package')
    const outputPlanning = byId.get('output-planning')
    const optimizer = byId.get('optimizer')
    const targetPrefix = byId.get('target-prefix')
    const sourceMaps = byId.get('source-maps')
    const browserTargets = byId.get('browser-targets')
    for (const capability of [nodeApi, zigPackage, outputPlanning, optimizer, targetPrefix, sourceMaps, browserTargets]) {
      assert.ok(capability)
    }
    nodeApi.behavior = nodeApi.behavior.replace(
      'The Unreleased source package root exposes',
      `The published \`zigcss@${activeVersion}\` prerelease package root exposes`,
    )
    zigPackage.behavior = zigPackage.behavior.replace(
      'This active source candidate is unpublished; stable delivery remains 0.6.0.',
      'This prerelease is published on npm `next`; stable delivery remains 0.6.0.',
    )
    outputPlanning.status = 'Published prerelease, safety boundary verified'
    outputPlanning.behavior = outputPlanning.behavior.replace(
      'The current Unreleased CLI',
      `The published ${activeVersion} prerelease CLI`,
    )
    optimizer.status = 'Experimental, published prerelease and acceptance-gated'
    optimizer.behavior = optimizer.behavior.replace(
      'In the current Unreleased CLI',
      `In the published ${activeVersion} prerelease CLI`,
    )
    for (const capability of [targetPrefix, sourceMaps, browserTargets]) {
      capability.status = 'Experimental, published prerelease all-syntax CLI/API verified'
      capability.behavior = capability.behavior
        .replace('In the current Unreleased source', `In the published ${activeVersion} prerelease`)
        .replace('The current Unreleased CLI', `The published ${activeVersion} prerelease CLI`)
    }
  })

  for (const [current, replacement] of [
    ['The Unreleased source package root exposes', `The published \`zigcss@${activeVersion}\` prerelease package root exposes`],
    ['This active source candidate is unpublished; stable delivery remains 0.6.0.', 'This prerelease is published on npm `next`; stable delivery remains 0.6.0.'],
    ['Unreleased, safety boundary verified', 'Published prerelease, safety boundary verified'],
    ['The current Unreleased CLI', `The published ${activeVersion} prerelease CLI`],
    ['Experimental, Unreleased and acceptance-gated', 'Experimental, published prerelease and acceptance-gated'],
    ['In the current Unreleased CLI', `In the published ${activeVersion} prerelease CLI`],
    ['Experimental, Unreleased all-syntax CLI/API verified', 'Experimental, published prerelease all-syntax CLI/API verified'],
    ['In the current Unreleased source', `In the published ${activeVersion} prerelease`],
  ]) {
    replaceEvery(sources, 'docs/src/content/docs/guide/status.md', current, replacement)
  }
  for (const [current, replacement] of [
    ['The current `Unreleased` source package additionally exposes', `The published \`zigcss@${activeVersion}\` prerelease package additionally exposes`],
    ['The current `Unreleased` package root maps', `The published \`zigcss@${activeVersion}\` prerelease package root maps`],
    ['this Unreleased API', 'this published prerelease API'],
    ['The current `Unreleased` source additionally owns', `The published ${activeVersion} prerelease additionally owns`],
    ['## Unreleased package installation recovery boundary', `## Published ${activeVersion} package installation recovery boundary`],
    ['No published npm version currently exposes the new recovery command.', `Published \`zigcss@${activeVersion}\` exposes the recovery command on npm \`next\`.`],
    ['Rows labeled current, source-checkout, or Unreleased describe this repository snapshot rather than the npm release; an experimental label alone does not imply that a capability is unpublished.', `Rows labeled current or source-checkout describe maintained repository proofs; the ${activeVersion} package capabilities above ship in the npm prerelease.`],
    ['The current `Unreleased` source adds typed experimental adapters', `Published ${activeVersion} remains the immutable prerelease CLI-launcher package and adds typed experimental adapters`],
    ['This Unreleased compiler enables', `This published ${activeVersion} prerelease compiler enables`],
  ]) {
    replace(sources, 'docs/src/content/docs/guide/status.md', current, replacement)
  }
  replace(
    sources,
    'docs/src/content/docs/guide/status.md',
    'The `NATIVE-009` published candidate `0.6.0-rc.2` is verified on the GitHub prerelease and npm `next` channels.',
    'The `NATIVE-009` historical candidate `0.6.0-rc.2` remains verified by its historically mutable GitHub prerelease and immutable npm version.',
  )

  // Publishing guide and user-facing install boundary.
  replace(
    sources,
    'NPM_PUBLISH.md',
    'It is currently `candidate-ready` with `candidateReady: true`',
    `Prerelease \`zigcss@${activeVersion}\` is published on npm \`next\``,
  )
  replace(
    sources,
    'NPM_PUBLISH.md',
    'The existing npm `next` tag remains bound to `0.6.0-rc.2`. Stable publication does not delete, overwrite, or republish that package, and it does not publish Homebrew, editor-extension, container, service, or other npm channels.',
    `Stable publication did not delete, overwrite, or republish the immutable \`0.6.0-rc.2\` package, and it did not publish Homebrew, editor-extension, container, service, or other npm channels.\n\nnpm \`next\` serves \`zigcss@${activeVersion}\`; npm \`latest\` remains \`zigcss@${publishedStableVersion}\`.`,
  )
  replace(sources, 'NPM_PUBLISH.md', '## Next candidate admission', `## Published ${activeVersion} prerelease`)
  replace(
    sources,
    'NPM_PUBLISH.md',
    'today `latest` is stable `0.6.0` while `next` still preserves the RC.',
    'today `latest` is stable `0.6.0`; the historical RC remains available only by its immutable exact version.',
  )
  replace(
    sources,
    'NPM_PUBLISH.md',
    'published immutable npm version `zigcss@0.6.0-rc.2` with provenance on `next`.',
    'published immutable npm version `zigcss@0.6.0-rc.2` with provenance. At publication time, this was the prerelease channel selection.',
  )
  replace(
    sources,
    'NPM_PUBLISH.md',
    'The seven-file npm package contains',
    'The 48-file npm package contains',
  )
  replace(
    sources,
    'NPM_PUBLISH.md',
    'The historical RC remains an immutable npm version installable with `zigcss@next` for comparison; the stable workflow never moves that tag.',
    `Install the published prerelease with \`zigcss@next\`.\n\nInstall the historical RC only by its immutable exact version \`zigcss@0.6.0-rc.2\`.`,
  )

  // Guides and maintained examples distinguish published package delivery
  // from the stricter source-checkout host proofs.
  replace(
    sources,
    'docs/src/content/docs/guide/build-from-source.md',
    'Source builds are the verified alternative to the published five-language native-graduated package.',
    `Source builds are the verified alternative to published stable \`zigcss@${publishedStableVersion}\` and the published \`zigcss@${activeVersion}\` prerelease.`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/css-compatibility.md',
    `current unpublished \`${activeVersion}\` recovery compiler`,
    `published \`${activeVersion}\` prerelease recovery compiler`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/format-compatibility.md',
    `The ZigCSS ${activeVersion} source candidate compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths; this candidate is not published.`,
    `ZigCSS ${activeVersion} prerelease is published on npm \`next\` and compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig paths.`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/format-compatibility.md',
    'Stable 0.6.0 contains the self-contained native five-language surface and is published on npm `latest` by the exact stable promotion workflow; historical `0.6.0-rc.2` remains available as an immutable npm version on `next`. Their GitHub releases predate Immutable Releases and read back `immutable: false`.',
    `Stable 0.6.0 contains the self-contained native five-language surface and remains on npm \`latest\` under the exact stable promotion workflow. Historical \`0.6.0-rc.2\` remains an immutable npm version available by exact version; both historical GitHub releases read back \`immutable: false\`.\n\nnpm \`next\` serves ZigCSS ${activeVersion}.`,
  )
  replaceEvery(
    sources,
    'docs/src/content/docs/guide/format-compatibility.md',
    'current `Unreleased`',
    `published ${activeVersion} prerelease`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/recovery-cli.md',
    `The ZigCSS ${activeVersion} source-built candidate owns one combined command for CSS, SCSS, indented Sass, Less, and Stylus. It is not published;`,
    `ZigCSS ${activeVersion} prerelease is published on npm \`next\` and owns one combined command for CSS, SCSS, indented Sass, Less, and Stylus;`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/recovery-cli.md',
    'This page documents the current `Unreleased` checkout.',
    `This page documents the published ${activeVersion} prerelease and current checkout.`,
  )
  replace(
    sources,
    'docs/src/content/docs/guide/recovery-cli.md',
    '## Unreleased package-manager lifecycle recovery',
    `## Published ${activeVersion} package-manager lifecycle recovery`,
  )
  replace(
    sources,
    'examples/build-systems/README.md',
    'These integrations are for the current `Unreleased` checkout only. Published stable ZigCSS 0.6.0 has no `--depfile` option.',
    `Published prerelease ZigCSS ${activeVersion} contains the verified \`--depfile\` contract; these maintained integration proofs still run against the exact current checkout. Published stable ZigCSS 0.6.0 has no \`--depfile\` option.`,
  )
  replace(
    sources,
    'examples/next-turbopack/README.md',
    'Build the current checkout\'s native binary before using this example. The\npublished `zigcss@0.6.0` binary predates the current `zigcss-node-v1` protocol,\nso this example is not a stable-release consumer yet.',
    `Published \`zigcss@${activeVersion}\` contains the \`zigcss/webpack\` loader and \`zigcss-node-v1\` protocol. Build the current checkout's native binary for this maintained host proof; published \`zigcss@0.6.0\` predates the protocol and is not a consumer path.`,
  )
  for (const [filename, current, replacement] of [
    [
      'examples/sveltekit/README.md',
      'Published ZigCSS 0.6.0 also predates the current `zigcss-node-v1` adapter protocol, so this example is a current-source-checkout proof only.',
      `Published \`zigcss@${activeVersion}\` contains the \`zigcss/vite\` adapter and current protocol; this maintained SvelteKit integration remains a current-source-checkout proof. Stable ZigCSS 0.6.0 predates that protocol.`,
    ],
    [
      'examples/astro/README.md',
      'This is current-source-checkout proof only: the published `zigcss@0.6.0` binary predates the current `zigcss-node-v1` protocol.',
      `Published \`zigcss@${activeVersion}\` contains the \`zigcss/vite\` adapter and current protocol; this maintained Astro integration remains a current-source-checkout proof. Stable \`zigcss@0.6.0\` predates that protocol.`,
    ],
    [
      'examples/nuxt/README.md',
      'Published ZigCSS 0.6.0 also predates the current `zigcss-node-v1` adapter protocol, so this example is a current-source-checkout proof only.',
      `Published \`zigcss@${activeVersion}\` contains the \`zigcss/vite\` adapter and current protocol; this maintained Nuxt integration remains a current-source-checkout proof. Stable ZigCSS 0.6.0 predates that protocol.`,
    ],
    [
      'examples/parcel/README.md',
      'Parcel compatibility, development watch mode, HMR, or stable ZigCSS 0.6.0\ndelivery; the published binary predates the protocol used by this source proof.',
      `Parcel compatibility, development watch mode, HMR, or stable ZigCSS 0.6.0 delivery. Published \`zigcss@${activeVersion}\` contains the root compiler protocol but no \`zigcss/parcel\` export, so this remains a local transformer proof.`,
    ],
  ]) {
    replace(sources, filename, current, replacement)
  }

  replace(
    sources,
    'CHANGELOG.md',
    `Prerelease target \`${activeVersion}\` is candidate-ready with \`candidateReady: true\` after all seven pre-tag gates passed. Published stable identity remains immutable at \`${publishedStableVersion}\`.\n\n### Added`,
    `## [${activeVersion}] - 2026-09-04\n\nReleased from protected tag \`v${activeVersion}\` as the first immutable GitHub Release and immutable \`zigcss@${activeVersion}\` on npm \`next\`.\n\n### Added`,
  )
}

function setPublicationFailedPhase(
  sources,
  { githubState = 'absent', npmState = 'absent', verifiedPreTagGates = 7 } = {},
) {
  assert.ok(['absent', 'draft', 'immutable-published'].includes(githubState))
  assert.ok(['absent', 'published-exact'].includes(npmState))
  assert.ok(Number.isInteger(verifiedPreTagGates) && verifiedPreTagGates >= 5 && verifiedPreTagGates <= 7)
  if (npmState === 'published-exact') {
    assert.equal(githubState, 'immutable-published')
    setClosedPhase(sources)
  } else {
    setCandidateReadyPhase(sources)
  }

  mutateJson(sources, 'release/next-release.json', contract => {
    delete contract.publicationEvidence
    contract.schemaVersion = 3
    contract.state = 'publication-failed'
    contract.candidateReady = false
    for (const gate of contract.gates.slice(verifiedPreTagGates, -1)) {
      gate.state = 'pending'
      gate.evidence = []
    }
    contract.gates.at(-1).state = 'failed'
    contract.gates.at(-1).evidence = ['failed publication evidence']
    contract.publicationFailureEvidence = {
      githubSurface: {
        state: githubState,
        publishedAt: githubState === 'immutable-published' ? '2026-09-04T12:34:00Z' : null,
      },
      npmSurface: { state: npmState },
    }
  })

  const surfaceSummary = `GitHub surface: \`${githubState}\`; npm surface: \`${npmState}\`.`
  const failureHeader = `> **Failed prerelease attempt: ${activeVersion} — identity permanently closed.**\n>\n> ${surfaceSummary}`
  if (npmState === 'published-exact') {
    replace(
      sources,
      'README.md',
      `ZigCSS \`${activeVersion}\` is the published prerelease on npm \`next\`.`,
      `Release attempt for \`v${activeVersion}\` failed after public surfaces were created. npm \`next\` still serves \`zigcss@${activeVersion}\`.`,
    )
    replace(
      sources,
      'README.md',
      `> **Published prerelease: ${activeVersion} — npm \`next\`.**`,
      failureHeader,
    )
    replace(
      sources,
      'README.md',
      '`candidateReady: false` after immutable publication',
      '`candidateReady: false` after failed publication',
    )
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      `ZigCSS ${activeVersion} is the published prerelease on npm \`next\`.`,
      `ZigCSS ${activeVersion} release attempt failed and the exact identity is permanently closed.\n\n${surfaceSummary}`,
    )
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      'Its `candidateReady` interlock is `false` after immutable publication',
      'Its `candidateReady` interlock is `false` after the failed publication attempt',
    )
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      '8 of 8 admission gates now carry recorded evidence',
      `${verifiedPreTagGates} of 8 admission gates are verified; the publication terminal is failed and carries recorded failure evidence`,
    )
    replace(
      sources,
      'docs/src/app/components/Home.tsx',
      `${activeVersion} · published prerelease · npm next`,
      `${activeVersion} · failed release identity · do not reuse`,
    )
    replace(sources, 'docs/src/app/components/Home.tsx', '8/8 admission gates verified', `${verifiedPreTagGates}/8 admission gates verified · publication failed`)
    replace(
      sources,
      'docs/src/app/components/GettingStarted.tsx',
      `ZigCSS ${activeVersion} is published on npm next; stable latest remains ${publishedStableVersion}.`,
      `Release attempt ${activeVersion} failed after the exact npm package was published; npm next still serves it and stable latest remains ${publishedStableVersion}.`,
    )
    replace(
      sources,
      'docs/src/content/docs/guide/builder-integrations.md',
      `The published ${activeVersion} prerelease and current source checkout have`,
      `After the failed ${activeVersion} release attempt, the published prerelease and current source checkout have`,
    )
    replace(
      sources,
      'docs/src/app/components/Features.tsx',
      `That evidence ships in published prerelease ${activeVersion} on npm next.`,
      `Release attempt ${activeVersion} failed; GitHub ${githubState}; npm ${npmState}; exact identity permanently closed. The exact npm package remains public on next.`,
    )
    mutateJson(sources, 'docs/src/data/capabilities.json', metadata => {
      const zigPackage = metadata.capabilities.find(capability => capability.id === 'zig-package')
      assert.ok(zigPackage)
      zigPackage.behavior = zigPackage.behavior.replace(
        'This prerelease is published on npm `next`; stable delivery remains 0.6.0.',
        `Release attempt ${activeVersion} is publication-failed: GitHub ${githubState}; npm ${npmState}; exact identity permanently closed. The exact npm prerelease is published despite the failed workflow terminal. Stable delivery remains 0.6.0.`,
      )
    })
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      'This prerelease is published on npm `next`; stable delivery remains 0.6.0.',
      `Release attempt ${activeVersion} is publication-failed: GitHub ${githubState}; npm ${npmState}; exact identity permanently closed. The exact npm prerelease is published despite the failed workflow terminal. Stable delivery remains 0.6.0.`,
    )
    replace(
      sources,
      'NPM_PUBLISH.md',
      `Prerelease \`zigcss@${activeVersion}\` is published on npm \`next\`; this selection does not authorize creating the tag or publishing either release surface.`,
      `Prerelease attempt \`zigcss@${activeVersion}\` failed and its exact identity is permanently closed. ${surfaceSummary} Select a new candidate version; never move, recreate, or reuse \`v${activeVersion}\`.`,
    )
    replace(
      sources,
      'CHANGELOG.md',
      `Released from protected tag \`v${activeVersion}\` as the first immutable GitHub Release and immutable \`zigcss@${activeVersion}\` on npm \`next\`.`,
      `An immutable GitHub Release and exact npm surfaces exist for \`${activeVersion}\`, but the Release workflow failed; this identity is permanently closed.`,
    )
  } else {
    replace(
      sources,
      'README.md',
      `Active source candidate \`${activeVersion}\` is unpublished.`,
      `Release attempt for \`v${activeVersion}\` failed and its exact identity is permanently closed. Active source package ${activeVersion} remains unavailable from npm.`,
    )
    replace(
      sources,
      'README.md',
      `> **Active source candidate: ${activeVersion} — unpublished.**`,
      failureHeader,
    )
    replace(sources, 'README.md', '`candidateReady: true`', '`candidateReady: false` after failed publication')
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      `Active source candidate ${activeVersion} is selected in \`release/next-release.json\` but is not published.`,
      `ZigCSS ${activeVersion} release attempt failed and the exact identity is permanently closed.\n\n${surfaceSummary}`,
    )
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      'Its `candidateReady` interlock is `true` after all seven pre-tag gates passed',
      'Its `candidateReady` interlock is `false` after the failed publication attempt',
    )
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      '7 of 8 admission gates now carry recorded evidence',
      `${verifiedPreTagGates} of 8 admission gates are verified; the publication terminal is failed and carries recorded failure evidence`,
    )
    replace(
      sources,
      'docs/src/app/components/Home.tsx',
      `${activeVersion} · unpublished source proofs`,
      `${activeVersion} · failed release identity · do not reuse`,
    )
    replace(
      sources,
      'docs/src/app/components/Home.tsx',
      '7/8 admission gates verified',
      `${verifiedPreTagGates}/8 admission gates verified · publication failed`,
    )
    replace(
      sources,
      'docs/src/app/components/GettingStarted.tsx',
      `Its active identity is the unpublished ${activeVersion} candidate.`,
      `Release attempt ${activeVersion} failed before npm publication; the exact identity is closed and stable latest remains ${publishedStableVersion}.`,
    )
    replace(
      sources,
      'docs/src/content/docs/guide/builder-integrations.md',
      `The current unpublished ${activeVersion} source checkout has`,
      `After the failed ${activeVersion} release attempt, the current unpublished source checkout has`,
    )
    replace(
      sources,
      'docs/src/app/components/Features.tsx',
      `That evidence belongs to unpublished candidate ${activeVersion}.`,
      `Release attempt ${activeVersion} failed; GitHub ${githubState}; npm ${npmState}; exact identity permanently closed. The source evidence remains checkout-only.`,
    )
    mutateJson(sources, 'docs/src/data/capabilities.json', metadata => {
      const zigPackage = metadata.capabilities.find(capability => capability.id === 'zig-package')
      assert.ok(zigPackage)
      zigPackage.behavior = zigPackage.behavior.replace(
        'This active source candidate is unpublished; stable delivery remains 0.6.0.',
        `Release attempt ${activeVersion} is publication-failed: GitHub ${githubState}; npm ${npmState}; exact identity permanently closed. The npm package surface is absent; source-checkout use remains available. Stable delivery remains 0.6.0.`,
      )
    })
    replace(
      sources,
      'docs/src/content/docs/guide/status.md',
      'This active source candidate is unpublished; stable delivery remains 0.6.0.',
      `Release attempt ${activeVersion} is publication-failed: GitHub ${githubState}; npm ${npmState}; exact identity permanently closed. The npm package surface is absent; source-checkout use remains available. Stable delivery remains 0.6.0.`,
    )
    replace(
      sources,
      'NPM_PUBLISH.md',
      'It is currently `candidate-ready` with `candidateReady: true`; this selection does not authorize creating the tag or publishing either release surface.',
      `Prerelease attempt \`zigcss@${activeVersion}\` failed and its exact identity is permanently closed. ${surfaceSummary} Select a new candidate version; never move, recreate, or reuse \`v${activeVersion}\`.`,
    )
    replace(
      sources,
      'CHANGELOG.md',
      `Prerelease target \`${activeVersion}\` is candidate-ready with \`candidateReady: true\` after all seven pre-tag gates passed. Published stable identity remains immutable at \`${publishedStableVersion}\`.`,
      `Prerelease attempt \`${activeVersion}\` failed; exact identity is permanently closed. GitHub surface \`${githubState}\`; npm surface \`absent\`. Select a new candidate version before another release attempt. Published stable identity remains immutable at \`${publishedStableVersion}\`.`,
    )
  }
}

test('all release, package, runtime, editor, container, formula, and documentation versions agree', () => {
  assert.deepEqual(validateReleaseVersion(), {
    version: activeVersion,
    vscodeVersion: activeBaseVersion,
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  })
})

test('release version policy accepts state-aware candidate-ready and closed public copy', () => {
  const expected = {
    version: activeVersion,
    vscodeVersion: activeBaseVersion,
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  }

  const ready = cloneSources()
  setCandidateReadyPhase(ready)
  assert.deepEqual(validateReleaseSources(ready), expected)

  const closed = cloneSources()
  setClosedPhase(closed)
  assert.deepEqual(validateReleaseSources(closed), expected)
})

test('release version policy accepts truthful publication-failed copy for every reachable surface state', () => {
  const expected = {
    version: activeVersion,
    vscodeVersion: activeBaseVersion,
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  }
  for (const surfaces of [
    { githubState: 'absent', npmState: 'absent', verifiedPreTagGates: 5 },
    { githubState: 'absent', npmState: 'absent', verifiedPreTagGates: 6 },
    { githubState: 'draft', npmState: 'absent' },
    { githubState: 'immutable-published', npmState: 'absent' },
    { githubState: 'immutable-published', npmState: 'published-exact' },
  ]) {
    const failed = cloneSources()
    setPublicationFailedPhase(failed, surfaces)
    assert.deepEqual(validateReleaseSources(failed), expected, JSON.stringify(surfaces))
  }
})

test('publication-failed public copy rejects success claims and requires a new candidate transition', () => {
  for (const surfaces of [
    { githubState: 'absent', npmState: 'absent' },
    { githubState: 'immutable-published', npmState: 'published-exact' },
  ]) {
    const staleHeader = cloneSources()
    setPublicationFailedPhase(staleHeader, surfaces)
    replace(
      staleHeader,
      'README.md',
      `> **Failed prerelease attempt: ${activeVersion} — identity permanently closed.**`,
      `> **Published prerelease: ${activeVersion} — npm \`next\`.**`,
    )
    assert.throws(() => validateReleaseSources(staleHeader), /README failed publication identity/)

    const staleSurfaces = cloneSources()
    setPublicationFailedPhase(staleSurfaces, surfaces)
    replace(
      staleSurfaces,
      'docs/src/content/docs/guide/status.md',
      `GitHub surface: \`${surfaces.githubState}\`; npm surface: \`${surfaces.npmState}\`.`,
      'GitHub surface: `absent`; npm surface: `published-exact`.',
    )
    assert.throws(() => validateReleaseSources(staleSurfaces), /status failed publication surfaces/)

    const missingTransition = cloneSources()
    setPublicationFailedPhase(missingTransition, surfaces)
    replace(
      missingTransition,
      'NPM_PUBLISH.md',
      `Select a new candidate version; never move, recreate, or reuse \`v${activeVersion}\`.`,
      'Retry the same version.',
    )
    assert.throws(() => validateReleaseSources(missingTransition), /npm guide failed publication operator transition/)
  }

  const falseNpmSuccess = cloneSources()
  setPublicationFailedPhase(falseNpmSuccess, { githubState: 'absent', npmState: 'absent' })
  replace(
    falseNpmSuccess,
    'README.md',
    `Active source package ${activeVersion} remains unavailable from npm.`,
    `npm \`next\` serves \`zigcss@${activeVersion}\`.`,
  )
  assert.throws(() => validateReleaseSources(falseNpmSuccess), /README absent npm failure boundary/)

  const falseWorkflowSuccess = cloneSources()
  setPublicationFailedPhase(falseWorkflowSuccess, {
    githubState: 'absent',
    npmState: 'absent',
    verifiedPreTagGates: 5,
  })
  injectCopyProbe(
    falseWorkflowSuccess,
    'README.md',
    `Release workflow succeeded for ${activeVersion}.`,
  )
  assert.throws(
    () => validateReleaseSources(falseWorkflowSuccess),
    /README\.md failed publication success contradiction/,
  )

  const falseUnpublished = cloneSources()
  setPublicationFailedPhase(falseUnpublished, {
    githubState: 'immutable-published',
    npmState: 'published-exact',
  })
  replace(
    falseUnpublished,
    'README.md',
    `npm \`next\` still serves \`zigcss@${activeVersion}\``,
    `zigcss@${activeVersion} is unpublished`,
  )
  assert.throws(() => validateReleaseSources(falseUnpublished), /README published npm failure boundary/)
})

test('release version policy rejects phase/count/schema and public-copy drift', () => {
  const outOfOrder = cloneSources()
  mutateJson(outOfOrder, 'release/next-release.json', contract => {
    contract.gates[0].state = 'pending'
    contract.gates[0].evidence = []
    contract.gates[5].state = 'verified'
    contract.gates[5].evidence = ['hosted evidence arrived early']
  })
  assert.throws(() => validateReleaseSources(outOfOrder), /planned next release candidate-selection must be verified/)

  const readyWithoutCopy = cloneSources()
  mutateJson(readyWithoutCopy, 'release/next-release.json', contract => {
    contract.state = 'candidate-ready'
    contract.candidateReady = true
    for (const gate of contract.gates.slice(0, -1)) {
      gate.state = 'verified'
      if (gate.evidence.length === 0) gate.evidence = [`verified evidence for ${gate.id}`]
    }
  })
  assert.throws(() => validateReleaseSources(readyWithoutCopy), /README admitted candidate interlock/)

  const wrongClosedSchema = cloneSources()
  setClosedPhase(wrongClosedSchema)
  mutateJson(wrongClosedSchema, 'release/next-release.json', contract => { contract.schemaVersion = 1 })
  assert.throws(() => validateReleaseSources(wrongClosedSchema), /closed next release schemaVersion must be 2/)

  const wrongFailedSchema = cloneSources()
  setPublicationFailedPhase(wrongFailedSchema, {
    githubState: 'absent',
    npmState: 'absent',
    verifiedPreTagGates: 5,
  })
  mutateJson(wrongFailedSchema, 'release/next-release.json', contract => { contract.schemaVersion = 2 })
  assert.throws(
    () => validateReleaseSources(wrongFailedSchema),
    /publication-failed next release schemaVersion must be 3/,
  )

  const regressedFailedGate = cloneSources()
  setPublicationFailedPhase(regressedFailedGate, {
    githubState: 'absent',
    npmState: 'absent',
    verifiedPreTagGates: 5,
  })
  mutateJson(regressedFailedGate, 'release/next-release.json', contract => {
    contract.gates[4].state = 'pending'
    contract.gates[4].evidence = []
  })
  assert.throws(
    () => validateReleaseSources(regressedFailedGate),
    /publication-failed next release documentation-validation must be verified/,
  )

  const outOfOrderFailedGate = cloneSources()
  setPublicationFailedPhase(outOfOrderFailedGate, {
    githubState: 'absent',
    npmState: 'absent',
    verifiedPreTagGates: 5,
  })
  mutateJson(outOfOrderFailedGate, 'release/next-release.json', contract => {
    contract.gates[6].state = 'verified'
    contract.gates[6].evidence = ['late evidence']
  })
  assert.throws(
    () => validateReleaseSources(outOfOrderFailedGate),
    /publication-failed next release pre-tag gates are out of order/,
  )

  const staleClosedHome = cloneSources()
  setClosedPhase(staleClosedHome)
  replace(
    staleClosedHome,
    'docs/src/app/components/Home.tsx',
    `${activeVersion} · published prerelease · npm next`,
    `${activeVersion} · unpublished source proofs`,
  )
  assert.throws(() => validateReleaseSources(staleClosedHome), /homepage published prerelease identity/)
})

test('closed release rejects stale candidate, Unreleased, and historical next copy across every public surface', () => {
  for (const filename of closedPublicReleasePaths) {
    const staleCandidate = cloneSources()
    setClosedPhase(staleCandidate)
    injectCopyProbe(staleCandidate, filename, `ZigCSS ${activeVersion} is not published.`)
    assert.throws(
      () => validateReleaseSources(staleCandidate),
      new RegExp(`${filename.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} closed candidate publication`),
      `${filename} must reject a stale unpublished candidate claim`,
    )

    const staleNext = cloneSources()
    setClosedPhase(staleNext)
    injectCopyProbe(staleNext, filename, 'npm next remains bound to 0.6.0-rc.2.')
    assert.throws(
      () => validateReleaseSources(staleNext),
      new RegExp(`${filename.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} current npm next identity`),
      `${filename} must reject the obsolete next dist-tag owner`,
    )
  }

  for (const filename of closedNoUnreleasedPaths) {
    const stale = cloneSources()
    setClosedPhase(stale)
    injectCopyProbe(stale, filename, 'This remains an Unreleased package capability.')
    assert.throws(
      () => validateReleaseSources(stale),
      new RegExp(`${filename.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} closed release phase`),
      `${filename} must reject an Unreleased marker after publication`,
    )
  }

  for (const filename of closedNoUnpublishedPaths) {
    const stale = cloneSources()
    setClosedPhase(stale)
    injectCopyProbe(stale, filename, 'This package capability is unpublished.')
    assert.throws(
      () => validateReleaseSources(stale),
      new RegExp(`${filename.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} closed release phase`),
      `${filename} must reject an unpublished marker after publication`,
    )
  }

  for (const [filename, label] of [
    ['README.md', 'README closed release phase outside benchmark boundary'],
    ['docs/src/app/components/Home.tsx', 'homepage closed release phase outside benchmark boundary'],
  ]) {
    const stale = cloneSources()
    setClosedPhase(stale)
    injectCopyProbe(stale, filename, 'This package capability is unpublished.')
    assert.throws(
      () => validateReleaseSources(stale),
      new RegExp(label),
      `${filename} must allow only the exact unpublished benchmark caveat`,
    )
  }
})

test('closed changelog date is the UTC GitHub publication date and package inventory stays exact', () => {
  const wrongDate = cloneSources()
  setClosedPhase(wrongDate)
  replace(wrongDate, 'CHANGELOG.md', `## [${activeVersion}] - 2026-09-04`, `## [${activeVersion}] - 2026-09-05`)
  assert.throws(
    () => validateReleaseSources(wrongDate),
    /published prerelease changelog target and UTC publication date/,
  )

  const invalidPublishedAt = cloneSources()
  setClosedPhase(invalidPublishedAt)
  mutateJson(invalidPublishedAt, 'release/next-release.json', contract => {
    contract.publicationEvidence.githubPublishedAt = '2026-02-30T12:34:00Z'
  })
  assert.throws(
    () => validateReleaseSources(invalidPublishedAt),
    /closed next release publicationEvidence\.githubPublishedAt must be a real canonical UTC timestamp/,
  )

  const stalePackageCount = cloneSources()
  setClosedPhase(stalePackageCount)
  replace(stalePackageCount, 'NPM_PUBLISH.md', 'The 48-file npm package contains', 'The seven-file npm package contains')
  assert.throws(() => validateReleaseSources(stalePackageCount), /npm guide exact package inventory/)
})

test('canonical versions and release tags fail closed', () => {
  assert.deepEqual(parseReleaseVersion('0.6.0'), {
    value: '0.6.0',
    base: '0.6.0',
    prerelease: null,
    build: null,
  })
  assert.equal(parseReleaseVersion('0.6.0-rc.2').prerelease, 'rc.2')
  for (const invalid of ['v0.6.0', '0.6', '00.6.0', '0.6.0-01', '0.6.0-']) {
    assert.throws(() => parseReleaseVersion(invalid), /not canonical Semantic Versioning/)
  }
  assert.equal(validateReleaseTag('0.6.0', 'v0.6.0'), true)
  assert.throws(() => validateReleaseTag('0.6.0', 'v0.6.0-rc.2'), /release tag must be v0\.6\.0/)
})

test('Semantic Versioning precedence is exact across stable, prerelease, and large numeric identifiers', () => {
  assert.equal(compareReleaseVersionPrecedence('0.7.0-rc.1', '0.6.0'), 1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0-rc.2', '0.6.0'), -1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0-rc.10', '0.6.0-rc.2'), 1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0', '0.6.0-rc.999'), 1)
  assert.equal(compareReleaseVersionPrecedence('0.6.0+new-build', '0.6.0+old-build'), 0)
  assert.equal(
    compareReleaseVersionPrecedence('9007199254740993.0.0', '9007199254740992.999.999'),
    1,
  )
})

test('[Unreleased] material-change detection ignores headings, comments, and explicit empty markers', () => {
  assert.equal(unreleasedSectionHasMaterialChanges(`
## [Unreleased]

No later stable identity is selected.

### Added

<!-- reserved for the next release -->

## [0.6.0] - 2026-08-18
`), false)
  assert.equal(unreleasedSectionHasMaterialChanges(`
## [Unreleased]

### Changed

- Add one verified behavior.

## [0.6.0] - 2026-08-18
`), true)
  assert.equal(unreleasedSectionHasMaterialChanges(`
## [Unreleased]

<!<!-- reserved for the next release -->-- material

## [0.6.0] - 2026-08-18
`), true)
  assert.throws(
    () => unreleasedSectionHasMaterialChanges('## [Unreleased]\n\n<!-- unterminated\n'),
    /unterminated HTML comment/,
  )
  assert.throws(
    () => unreleasedSectionHasMaterialChanges('## [Unreleased]\n\n## [Unreleased]\n'),
    /exactly one \[Unreleased\] section/,
  )
})

test('material Unreleased changes require an active identity beyond published stable', () => {
  const equalStable = cloneSources()
  setActiveSourceVersion(equalStable, publishedStableVersion)
  assert.throws(
    () => validateReleaseSources(equalStable),
    /active source version 0\.6\.0 must advance beyond published stable 0\.6\.0 because \[Unreleased\] contains material changes/,
  )

  const equalPrecedence = cloneSources()
  setActiveSourceVersion(equalPrecedence, '0.6.0+local')
  assert.throws(
    () => validateReleaseSources(equalPrecedence),
    /must advance beyond published stable 0\.6\.0 because \[Unreleased\] contains material changes/,
  )

  const emptyUnreleased = cloneSources()
  setActiveSourceVersion(emptyUnreleased, publishedStableVersion)
  emptyUnreleased.set(
    'CHANGELOG.md',
    emptyUnreleased.get('CHANGELOG.md').replace(
      /## \[Unreleased\][\s\S]*?(?=## \[0\.6\.0\])/,
      '## [Unreleased]\n\nNo later stable identity is selected.\n\n',
    ),
  )
  assert.deepEqual(validateReleaseSources(emptyUnreleased), {
    version: publishedStableVersion,
    vscodeVersion: publishedStableVersion,
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  })
})

test('active source may advance without rewriting closed published-stable evidence', () => {
  const future = cloneSources()
  setActiveSourceVersion(future, '0.8.0-rc.1')

  assert.deepEqual(validateReleaseSources(future), {
    version: '0.8.0-rc.1',
    vscodeVersion: '0.8.0',
    publishedStableVersion,
    surfaces: synchronizedSurfaceCount,
  })
  assert.match(future.get('release/stable-promotion.json'), /"candidateVersion": "0\.6\.0"/)
  assert.match(future.get('Formula/zigcss.rb'), /version "0\.6\.0"/)
  assert.match(future.get('README.md'), /Stable package identity: 0\.6\.0/)

  const rollback = cloneSources()
  setActiveSourceVersion(rollback, '0.5.9')
  assert.throws(
    () => validateReleaseSources(rollback),
    /active source version 0\.5\.9 is older than published stable 0\.6\.0/,
  )
})

test('active and closed published-stable documentation boundaries fail independently', () => {
  const missingReadmeBoundary = cloneSources()
  replace(
    missingReadmeBoundary,
    'README.md',
    'Active source versioning is independent of closed published-stable evidence',
    'Source and stable versions are unrelated',
  )
  assert.throws(() => validateReleaseSources(missingReadmeBoundary), /README active versus published version boundary/)

  const missingStatusBoundary = cloneSources()
  replace(
    missingStatusBoundary,
    'docs/src/content/docs/guide/status.md',
    'The active source version may advance without rewriting that closed publication record or the verified Homebrew formula',
    'The source can advance',
  )
  assert.throws(() => validateReleaseSources(missingStatusBoundary), /status guide active versus published version boundary/)

  const staleStatusGateProgress = cloneSources()
  replace(
    staleStatusGateProgress,
    'docs/src/content/docs/guide/status.md',
    '5 of 8 admission gates now carry recorded evidence',
    '4 of 8 admission gates now carry recorded evidence',
  )
  assert.throws(() => validateReleaseSources(staleStatusGateProgress), /status guide candidate gate progress/)

  const staleHomeGateProgress = cloneSources()
  replace(
    staleHomeGateProgress,
    'docs/src/app/components/Home.tsx',
    '5/8 admission gates verified',
    '4/8 admission gates verified',
  )
  assert.throws(() => validateReleaseSources(staleHomeGateProgress), /home candidate gate progress/)

  const missingCssStableBoundary = cloneSources()
  replace(
    missingCssStableBoundary,
    'docs/src/content/docs/guide/css-compatibility.md',
    'Published stable 0.6.0 predates this parser contract',
    'The published package has this parser contract',
  )
  assert.throws(() => validateReleaseSources(missingCssStableBoundary), /CSS guide published stable boundary/)

  const futurePublishedClaimDrift = cloneSources()
  setActiveSourceVersion(futurePublishedClaimDrift, '0.8.0-rc.1')
  replace(futurePublishedClaimDrift, 'README.md', 'Stable package identity: 0.6.0', 'Stable package identity: 0.7.0')
  assert.throws(() => validateReleaseSources(futurePublishedClaimDrift), /README published stable identity header/)

  const futureActiveClaimDrift = cloneSources()
  setActiveSourceVersion(futureActiveClaimDrift, '0.8.0-rc.1')
  replace(futureActiveClaimDrift, 'docs/src/content/docs/guide/build-from-source.md', 'package `zigcss` 0.8.0-rc.1', 'package `zigcss` 0.6.0')
  assert.throws(() => validateReleaseSources(futureActiveClaimDrift), /build guide stable identity/)

  for (const filename of [
    'docs/src/content/docs/guide/builder-integrations.md',
    'examples/build-systems/README.md',
    'examples/next-turbopack/README.md',
    'examples/sveltekit/README.md',
    'examples/astro/README.md',
    'examples/nuxt/README.md',
    'examples/parcel/README.md',
  ]) {
    const builderDrift = cloneSources()
    replace(builderDrift, filename, '0.6.0', '9.9.9')
    assert.throws(
      () => validateReleaseSources(builderDrift),
      /builder guide published stable identity|README\.md published stable identity/,
      `${filename} must remain bound to immutable published stable evidence`,
    )
  }

  for (const filename of [
    'docs/src/content/docs/guide/builder-integrations.md',
    'examples/build-systems/README.md',
    'examples/next-turbopack/README.md',
    'examples/sveltekit/README.md',
    'examples/astro/README.md',
    'examples/nuxt/README.md',
    'examples/parcel/README.md',
  ]) {
    const toolchainDrift = cloneSources()
    replace(toolchainDrift, filename, '0.15.2', '0.14.0')
    assert.throws(
      () => validateReleaseSources(toolchainDrift),
      /minimum Zig version/,
      `${filename} must remain bound to build.zig.zon minimum Zig`,
    )
  }
})

test('manifest, lockfile, Zig, CLI, and Marketplace mapping drift fails closed', () => {
  const rootLock = cloneSources()
  replace(rootLock, 'package-lock.json', `"version": "${activeVersion}"`, '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(rootLock), /root npm lock version/)

  const docsLock = cloneSources()
  replace(docsLock, 'docs/package-lock.json', `"version": "${activeVersion}"`, '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(docsLock), /documentation linked ZigCSS version/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/package.json', `"version": "${activeBaseVersion}"`, '"version": "9.9.9"')
  assert.throws(() => validateReleaseSources(vscode), /VS Code Marketplace package version/)

  const zig = cloneSources()
  replace(zig, 'build.zig.zon', `.version = "${activeVersion}"`, '.version = "9.9.9"')
  assert.throws(() => validateReleaseSources(zig), /Zig package version/)

  const cli = cloneSources()
  replace(cli, 'src/main.zig', `const version = "${activeVersion}";`, 'const version = "9.9.9";')
  assert.throws(() => validateReleaseSources(cli), /CLI version constant/)

  const nativeCandidate = cloneSources()
  replace(nativeCandidate, 'tests/preprocessors/native/contract.json',
    '"candidateVersion": "0.6.0-rc.2"', '"candidateVersion": "0.6.0-rc.3"')
  assert.throws(() => validateReleaseSources(nativeCandidate), /native historical candidate version/)

  const closedInterlock = cloneSources()
  replace(closedInterlock, 'tests/preprocessors/native/contract.json',
    '"nativeReleaseReady": true', '"nativeReleaseReady": false')
  assert.throws(() => validateReleaseSources(closedInterlock), /native release interlock/)

  const missingGraduatedVersion = cloneSources()
  replace(missingGraduatedVersion, 'tests/preprocessors/native/contract.json',
    '"nativeReleaseVersion": "0.6.0-rc.2"', '"nativeReleaseVersion": null')
  assert.throws(() => validateReleaseSources(missingGraduatedVersion), /graduated native release version/)
})

test('Homebrew, Docker, changelog, and public claim drift fails closed', () => {
  const formula = cloneSources()
  replace(formula, 'Formula/zigcss.rb', 'version "0.6.0"', 'version "0.6.0-rc.2"')
  assert.throws(() => validateReleaseSources(formula), /Homebrew published stable version/)

  const formulaCommit = cloneSources()
  replace(formulaCommit, 'Formula/zigcss.rb', '6786655d66ca65c5a06421c8ed70d84183722dce', '0'.repeat(40))
  assert.throws(() => validateReleaseSources(formulaCommit), /Homebrew published stable source commit/)

  const formulaHash = cloneSources()
  replace(formulaHash, 'Formula/zigcss.rb', '059b5732816655a55d9c9787168809f5f58c2fff35504ddc0c5d3d0c9de63010', '0'.repeat(64))
  assert.throws(() => validateReleaseSources(formulaHash), /Homebrew published stable source SHA-256/)

  const formulaToolchain = cloneSources()
  replace(formulaToolchain, 'Formula/zigcss.rb', 'depends_on "zig@0.15"', 'depends_on "zig"')
  assert.throws(() => validateReleaseSources(formulaToolchain), /Homebrew Zig dependency/)

  const homebrewGuide = cloneSources()
  replace(homebrewGuide, 'homebrew-install.md', 'stable ZigCSS `0.6.0`', 'stable ZigCSS `9.9.9`')
  assert.throws(() => validateReleaseSources(homebrewGuide), /Homebrew guide published stable identity/)

  const homebrewTapBoundary = cloneSources()
  replace(homebrewTapBoundary, 'homebrew-install.md', 'not a claim that a public Homebrew tap exists', 'available from the public Homebrew tap')
  assert.throws(() => validateReleaseSources(homebrewTapBoundary), /Homebrew guide tap boundary/)

  const npmBuildPreflight = cloneSources()
  replace(npmBuildPreflight, 'NPM_PUBLISH.md', 'successful same-repository `main` push run', 'successful fork pull-request run')
  assert.throws(() => validateReleaseSources(npmBuildPreflight), /npm publishing guide exact-SHA Build preflight/)

  const statusBuildPreflight = cloneSources()
  replace(statusBuildPreflight, 'docs/src/content/docs/guide/status.md', 'successful same-repository `main` push run', 'successful fork pull-request run')
  assert.throws(() => validateReleaseSources(statusBuildPreflight), /status exact-SHA Build preflight/)

  const npmDraftAuthority = cloneSources()
  replace(
    npmDraftAuthority,
    'NPM_PUBLISH.md',
    'Overwrite authority is confined to exact-tag draft reconciliation and never applies to an immutable published asset',
    'Published release assets may be overwritten',
  )
  assert.throws(() => validateReleaseSources(npmDraftAuthority), /npm publishing guide draft reconciliation boundary/)

  const capabilityDraftAuthority = cloneSources()
  replace(
    capabilityDraftAuthority,
    'docs/src/data/capabilities.json',
    'confines overwrite to expected draft assets',
    'allows release asset overwrite',
  )
  assert.throws(() => validateReleaseSources(capabilityDraftAuthority), /release-artifact draft reconciliation capability/)

  const capabilityCodeQl = cloneSources()
  replace(
    capabilityCodeQl,
    'docs/src/data/capabilities.json',
    'same-commit Build and default-setup CodeQL for Actions, JavaScript/TypeScript, and Ruby',
    'an unspecified security scan',
  )
  assert.throws(() => validateReleaseSources(capabilityCodeQl), /release-artifact CodeQL admission capability/)

  const capabilityTagProtection = cloneSources()
  replace(
    capabilityTagProtection,
    'docs/src/data/capabilities.json',
    'Repository ruleset 22261144 (`Protect release tags`)',
    'An unspecified tag policy',
  )
  assert.throws(() => validateReleaseSources(capabilityTagProtection), /release-artifact protected-tag capability/)

  const capabilityFailedTerminal = cloneSources()
  replace(
    capabilityFailedTerminal,
    'docs/src/data/capabilities.json',
    'A terminal non-success tag workflow must transition to schema 3 `publication-failed`',
    'A failed workflow may be retried on the same identity',
  )
  assert.throws(() => validateReleaseSources(capabilityFailedTerminal), /release-artifact failed-terminal capability/)

  const npmTagProtection = cloneSources()
  replace(
    npmTagProtection,
    'NPM_PUBLISH.md',
    'repository ruleset 22261144 (`Protect release tags`) as active',
    'an unspecified repository rule as active',
  )
  assert.throws(() => validateReleaseSources(npmTagProtection), /npm publishing guide draft reconciliation boundary/)

  const docker = cloneSources()
  replace(docker, 'Dockerfile.docs', `ARG ZIGCSS_VERSION=${activeVersion}`, 'ARG ZIGCSS_VERSION=9.9.9')
  assert.throws(() => validateReleaseSources(docker), /Dockerfile\.docs product version/)

  const releaseDocker = cloneSources()
  replace(releaseDocker, 'Dockerfile.release', `ARG ZIGCSS_VERSION=${activeVersion}`, 'ARG ZIGCSS_VERSION=9.9.9')
  assert.throws(() => validateReleaseSources(releaseDocker), /Dockerfile\.release product version/)

  const changelog = cloneSources()
  replace(changelog, 'CHANGELOG.md', '## [0.6.0] - 2026-08-18', '## [9.9.9] - 2026-08-18')
  assert.throws(() => validateReleaseSources(changelog), /stable changelog target/)

  const docs = cloneSources()
  docs.set('README.md', docs.get('README.md').replaceAll('Stable package identity: 0.6.0', 'Stable package identity: 9.9.9'))
  assert.throws(() => validateReleaseSources(docs), /README published stable identity header/)

  const npmGuide = cloneSources()
  replace(npmGuide, 'NPM_PUBLISH.md', 'Stable `zigcss@0.6.0` is published on npm `latest`', 'Stable `zigcss@9.9.9` is published on npm `latest`')
  assert.throws(() => validateReleaseSources(npmGuide), /npm publishing guide stable identity/)

  const staticRoute = cloneSources()
  replace(staticRoute, 'docs/src/data/seo-routes.mjs', 'Install and run ZigCSS 0.6.0', 'Install and run ZigCSS 9.9.9')
  assert.throws(() => validateReleaseSources(staticRoute), /published static route identity/)
})

test('CI ordering, release-tag preflight, and VS Code prerelease packaging fail closed', () => {
  const build = cloneSources()
  replace(build, '.github/workflows/build.yml', '- name: Verify release version policy', '- name: Removed release version policy')
  assert.throws(() => validateReleaseSources(build), /before npm installation/)

  const release = cloneSources()
  replace(release, '.github/workflows/release.yml', 'npm run check:version -- --tag "$GITHUB_REF_NAME"', 'npm run check:version')
  assert.throws(() => validateReleaseSources(release), /before building any release artifact/)

  const vscode = cloneSources()
  replace(vscode, 'vscode-extension/scripts/verify-package.mjs', "    '--pre-release',\n", '')
  assert.throws(() => validateReleaseSources(vscode), /VS Code package verifier/)

  const inventory = cloneSources()
  inventory.set('unowned-version.txt', '0.6.0\n')
  assert.throws(() => validateReleaseSources(inventory), /release surface inventory changed/)

  const npmPolicy = cloneSources()
  replace(npmPolicy, 'package.json', ' scripts/verify-github-release-assets.test.mjs', '')
  assert.throws(() => validateReleaseSources(npmPolicy), /npm publication policy test script/)

  const archivePolicy = cloneSources()
  replace(archivePolicy, 'package.json', 'scripts/create-release-archive.test.mjs ', '')
  assert.throws(() => validateReleaseSources(archivePolicy), /release archive and metadata policy test script/)
})

test('release source inventory rejects symlink substitution', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-version-'))
  try {
    for (const relativePath of releaseSourcePaths) {
      const destination = path.join(temporary, relativePath)
      fs.mkdirSync(path.dirname(destination), { recursive: true })
      fs.copyFileSync(path.join(repositoryRoot, relativePath), destination)
    }

    const victim = path.join(temporary, 'VERSION')
    fs.rmSync(victim)
    fs.symlinkSync(path.join(repositoryRoot, 'VERSION'), victim)
    assert.throws(() => readReleaseSources(temporary), /VERSION must be a regular non-symlink file/)
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})

test('release source inventory normalizes checkout CRLF and rejects bare carriage returns', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'zigcss-release-version-crlf-'))
  try {
    for (const relativePath of releaseSourcePaths) {
      const destination = path.join(temporary, relativePath)
      fs.mkdirSync(path.dirname(destination), { recursive: true })
      const source = fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8')
      fs.writeFileSync(destination, source.replaceAll('\n', '\r\n'))
    }

    assert.deepEqual(validateReleaseVersion(temporary), {
      version: activeVersion,
      vscodeVersion: activeBaseVersion,
      publishedStableVersion,
      surfaces: synchronizedSurfaceCount,
    })

    fs.writeFileSync(path.join(temporary, 'VERSION'), `${activeVersion}\r`)
    assert.throws(
      () => readReleaseSources(temporary),
      /VERSION contains an unsupported bare carriage return/,
    )
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true })
  }
})
