"""Offline diagram rendering and browser clipboard uploads, including live rerender."""

import importlib.util
import json
import os
import unittest
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from test_markdown import PreviewTransportTests
from test_vim import ROOT


spec = importlib.util.spec_from_file_location('markdown_diagrams', ROOT / 'markdown/diagrams.py')
diagrams = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagrams)
urlopen = build_opener(ProxyHandler({})).open


class DiagramTransportTests(PreviewTransportTests):
    @unittest.skipUnless(diagrams.java_runtime(), 'PlantUML needs a Java runtime')
    def test_local_plantuml_svg_and_rejected_external_access(self):
        self.update('# Diagrams')
        source = '@startuml\nclass Reader\nclass Document\nReader --> Document\n@enduml'
        request = Request(self.url + 'plantuml', data=json.dumps({'source': source}).encode(),
                          headers={'Content-Type': 'application/json'})
        first = urlopen(request).read()
        self.assertIn(b'<svg', first)
        self.assertIn(b'Reader', first)
        self.assertIn(b'Document', first)
        self.assertEqual(first, urlopen(request).read())
        for source in ['!include /etc/passwd', '!includeurl https://example.com/a',
                       '%getenv("HOME")']:
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + 'plantuml', data=json.dumps({'source': source}).encode()))
            self.assertEqual(error.exception.code, 400)

    def test_upload_requires_current_paste_request_and_same_origin(self):
        self.update('# Images')
        for headers in [{}, {'Origin': 'https://example.com'}]:
            with self.assertRaises(HTTPError) as error:
                urlopen(Request(self.url + 'image?request=1', data=b'not an image', headers=headers))
            self.assertIn(error.exception.code, [403, 409])
        self.assertFalse((self.work / 'imgs').exists())


@unittest.skipUnless(os.environ.get('VIM_MARKDOWN_BROWSER_TEST'), 'set VIM_MARKDOWN_BROWSER_TEST=1')
class DiagramBrowserTests(PreviewTransportTests):
    def test_mermaid_flowchart_gantt_plantuml_clipboard_and_image_layout(self):
        from playwright.sync_api import sync_playwright
        source = '''# Diagrams

```mermaid
flowchart LR
  A[Start] --> B[Finish]
```

```mermaid
gantt
  title Local schedule
  dateFormat YYYY-MM-DD
  section Work
  Design :a, 2026-10-16, 2d
  Test :after a, 1d
```

```plantuml
@startuml
Alice -> Bob: Offline hello
@enduml
```

![sample](sample.svg){width=60% align=center}
'''
        self.work.joinpath('sample.svg').write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="blue"/></svg>')
        self.update(source)
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path=os.environ.get('VIM_MARKDOWN_CHROME', '/opt/google/chrome/chrome'),
                headless=True, args=['--no-sandbox'])
            context = browser.new_context(viewport={'width': 1200, 'height': 900},
                                          permissions=['clipboard-read', 'clipboard-write'])
            page = context.new_page()
            errors, external = [], []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: external.append(request.url)
                    if not request.url.startswith(self.url) and not request.url.startswith('data:') else None)
            page.goto(self.url)
            page.wait_for_function('() => document.querySelectorAll(".diagram-ready").length === 3', timeout=30000)
            self.assertEqual(page.locator('.diagram-error').count(), 0)
            self.assertIn('Start', page.locator('.diagram-output').nth(0).inner_text())
            self.assertIn('Local schedule', page.locator('.diagram-output').nth(1).inner_text())
            page.wait_for_function('() => document.querySelector(`img[alt="PlantUML 图表"]`).naturalWidth > 0')
            image = page.locator('img[alt="sample"]')
            self.assertEqual(image.get_attribute('class'), 'image-align-center')
            self.assertEqual(image.evaluate('image => image.style.width'), '60%')
            self.process.stdin.write(json.dumps({'image_request': {'id': 42, 'folder': 'imgs',
                                                                   'name': 'browser-shot'}}) + '\n')
            self.process.stdin.flush()
            page.wait_for_function('() => document.querySelector("#paste-image").textContent.includes("等待中")')
            page.evaluate('''async () => {
              const canvas = document.createElement('canvas'); canvas.width = 4; canvas.height = 4;
              const ctx = canvas.getContext('2d'); ctx.fillStyle = '#7aa2f7'; ctx.fillRect(0,0,4,4);
              const blob = await new Promise(resolve => canvas.toBlob(resolve));
              await navigator.clipboard.write([new ClipboardItem({'image/png': blob})]);
            }''')
            page.locator('#paste-image').click()
            page.wait_for_function('() => document.querySelector("#paste-image").textContent.includes("已保存图片")')
            self.assertTrue((self.work / 'imgs/browser-shot.png').read_bytes().startswith(b'\x89PNG'))
            self.update(source.replace('Start', 'Changed'))
            page.wait_for_function('() => document.querySelectorAll(".diagram-ready").length === 3 && document.querySelector(".diagram-output").textContent.includes("Changed")')
            pdf = page.pdf()
            self.assertGreater(len(pdf), 1000)
            self.assertFalse(external, external)
            self.assertFalse(errors, errors)
            context.close()
            browser.close()
