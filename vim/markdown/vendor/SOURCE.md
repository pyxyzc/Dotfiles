# Offline preview dependencies

The offline bundle contains pinned distributions, with licenses beside each library:

| Package | Version | Upstream | License |
| --- | --- | --- | --- |
| markdown-it | 14.1.0 | https://github.com/markdown-it/markdown-it | MIT |
| @highlightjs/cdn-assets | 11.11.1 | https://github.com/highlightjs/highlight.js | BSD-3-Clause |
| katex | 0.16.22 | https://github.com/KaTeX/KaTeX | MIT |
| mermaid | 12.2.0 | https://github.com/mermaid-js/mermaid | MIT |
| plantuml-mit | 1.2026.8 | https://github.com/plantuml/plantuml | MIT build, bundled notices |

`manifest.json` records the exact npm tarball URLs, their SHA-512 integrity, and SHA-256
of every deployed library, stylesheet, license and font. Tarball integrity was verified
before extraction. JavaScript is unmodified. KaTeX CSS keeps the original woff2 font
sources and removes the woff/ttf fallbacks; all referenced woff2 fonts are included.
The runtime never contacts npm or a CDN. Node and npm are unnecessary on the target machine.
Mermaid is loaded only for diagram fences. PlantUML is the unmodified MIT release JAR; its
GitHub release SHA-256 is checked and recorded in the manifest. `LICENSE.plantuml` is the
distribution's full `-license` output, including bundled component notices. PlantUML needs
a local Java runtime and uses Smetana when Graphviz is unavailable. Rendering stays local.

Interactive Markdown snippets use the unmodified, pinned `hrsh7th/vim-vsnip` runtime in
`../../vendor/vim-vsnip/`; that directory has its own MIT license and integrity manifest.

The editor and preview interaction design references:

- https://github.com/MeanderingProgrammer/render-markdown.nvim — modal rendering and heading colors.
- https://github.com/OXY2DEV/markview.nvim — native block layout, custom checkbox states and hybrid reading.
- https://github.com/preservim/vim-markdown — heading navigation, outline, tables and list editing.
- https://github.com/iamcco/markdown-preview.nvim — unsaved live preview and synchronized scrolling.

These plugins are design references; their source code is not included in this module.
