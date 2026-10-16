"""Render pinned local PlantUML, with bounded work and an in-memory content cache."""

from collections import OrderedDict
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading


JAR = Path(__file__).resolve().parent / 'vendor/plantuml.jar'
_cache = OrderedDict()
_lock = threading.Lock()
_workers = threading.BoundedSemaphore(2)


def java_runtime():
    java = os.environ.get('VIM_MARKDOWN_JAVA') or shutil.which('java')
    if not java:
        runtimes = sorted((Path.home() / '.local/share/vim-lite/java/usr/lib/jvm').glob('*/bin/java'))
        java = str(runtimes[-1]) if runtimes else None
    return java


def render_plantuml(source):
    if len(source.encode('utf-8')) > 128 * 1024:
        raise ValueError('PlantUML source exceeds 128 KiB')
    if re.search(r'!\s*(?:include|import)|%\s*(?:load|read|file|ifdef|ifndef|getenv)', source, re.I):
        raise ValueError('PlantUML preview does not load external files, URLs or environment variables')
    java = java_runtime()
    if not java or not JAR.is_file():
        raise ValueError('PlantUML needs a local Java runtime; install default-jre-headless and graphviz')
    digest = hashlib.sha256(source.encode('utf-8')).hexdigest()
    with _lock:
        if digest in _cache:
            _cache.move_to_end(digest)
            return _cache[digest]
    if not re.search(r'^\s*@start\w+', source, re.M):
        source = '@startuml\n' + source + '\n@enduml'
    palette = ('skinparam backgroundColor #16161e\n'
               'skinparam defaultFontColor #c0caf5\n'
               'skinparam ArrowColor #7dcfff\n'
               'skinparam participantBackgroundColor #24283b\n'
               'skinparam participantBorderColor #7aa2f7\n'
               'skinparam participantFontColor #c0caf5\n'
               'skinparam sequenceLifeLineBorderColor #565f89\n'
               'skinparam sequenceLifeLineBackgroundColor #24283b\n'
               'skinparam classBackgroundColor #24283b\n'
               'skinparam classBorderColor #7aa2f7\n'
               'skinparam classFontColor #c0caf5\n'
               'skinparam shadowing false\n')
    source = re.sub(r'(^\s*@startuml[^\n]*\n)', lambda match: match[1] + palette,
                    source, count=1, flags=re.M)
    if not shutil.which('dot') and re.search(r'^\s*@startuml\b', source, re.M):
        source = re.sub(r'(^\s*@startuml[^\n]*\n)', r'\1!pragma layout smetana\n', source, count=1, flags=re.M)
    if not _workers.acquire(timeout=2):
        raise ValueError('PlantUML is busy; retry after the other diagrams finish')
    try:
        result = subprocess.run(
            [java, '-Djava.awt.headless=true', '-DPLANTUML_SECURITY_PROFILE=SANDBOX',
             '-Xmx128m', '-jar', str(JAR), '-charset', 'UTF-8', '-tsvg', '-pipe'],
            input=source.encode('utf-8'), capture_output=True, timeout=15,
            cwd=str(JAR.parent), env={**os.environ, 'PLANTUML_SECURITY_PROFILE': 'SANDBOX'})
    except subprocess.TimeoutExpired as error:
        raise ValueError('PlantUML rendering exceeded 15 seconds') from error
    finally:
        _workers.release()
    if result.returncode or b'<svg' not in result.stdout:
        raise ValueError('PlantUML could not render this diagram; check its syntax and Graphviz installation')
    data = result.stdout
    with _lock:
        _cache[digest] = data
        while len(_cache) > 64:
            _cache.popitem(last=False)
    return data
