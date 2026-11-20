"""Exercise the shipping installer using a real Chromium browser."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from playwright.sync_api import sync_playwright

out = Path("web-evidence")
out.mkdir(exist_ok=True)
hosts = [f"bd{n:02d}.lab.test" for n in range(1, 4)]
base = "http://" + os.environ["AMBARI_IP"] + ":8080"
repo = "http://repo.lab.test:8081/app/"
password = subprocess.check_output(["docker", "exec", hosts[0], "cat", "/root/hive.pass"], text=True).strip()

with sync_playwright() as engine:
    browser = engine.chromium.launch(executable_path=shutil.which("google-chrome"), args=["--disable-dev-shm-usage"])
    page = browser.new_page(viewport={"width": 1600, "height": 1100})
    page.set_default_timeout(25000)

    def shot(label):
        name = re.sub(r"[^A-Za-z0-9_-]+", "-", label)
        page.screenshot(path=str(out / (name + ".png")), mask=[page.locator("input[type=password]")], timeout=12000)
        print("Browser checkpoint", name, page.url.split("#")[-1], flush=True)

    def record(response):
        from urllib.parse import urlsplit
        path = urlsplit(response.url).path
        if ("/api/v1/" in path and response.request.method != "GET") or response.status >= 400:
            with (out / "requests.jsonl").open("a") as log:
                print(json.dumps([response.request.method, path, response.status]), file=log)

    page.on("response", record)
    page.on("pageerror", lambda error: print("Browser error:", str(error).replace(password, "[redacted]")[:1200], flush=True))
    try:
        page.goto(base, wait_until="domcontentloaded")
        page.wait_for_timeout(2500)
        shot("00-login")
        from initial import initial
        from services import services
        initial(page, base, hosts, repo, shot)
        services(page, hosts, password, shot)
    except Exception:
        print("URL", page.url.split("?")[0], flush=True)
        text = page.locator("body").inner_text(timeout=6000)
        print(text.replace(password, "[redacted]")[-6500:], flush=True)
        print("Visible controls:", page.locator("button:visible, input:visible, select:visible").evaluate_all(
            "(nodes) => nodes.map(e => [e.tagName, e.type, e.id, e.name, e.getAttribute('data-qa'), e.placeholder, e.disabled])"
        )[:120], flush=True)
        shot("failure")
        raise
    finally:
        browser.close()
