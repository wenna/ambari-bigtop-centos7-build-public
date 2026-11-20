"""Drive the Ambari install wizard through confirmation of the registered agents."""
import re

from playwright.sync_api import expect


def initial(page, base, hosts, repo, shot):
    if page.url == "about:blank":
        page.goto(base)
    page.locator(".login-username").fill("admin")
    page.locator(".login-password").fill("admin")
    page.get_by_role("button", name=re.compile("Sign In", re.I)).click()
    page.get_by_text("Launch Install Wizard", exact=True).first.click(timeout=90000)
    cluster_name = page.locator("#cluster-name")
    cluster_name.press_sequentially("weblab", delay=100)
    cluster_name.press("Tab")
    expect(cluster_name).to_have_value("weblab")
    shot("01-cluster-name")
    forward = page.locator(".wizard-footer button.btn-success")
    if not forward.is_enabled():
        print("Cluster name validation", page.evaluate("""() => {
          const c = require('app').router.get('wizardStep0Controller');
          return ['content.cluster.name','invalidClusterName','hasNotStacksAvailable','isSubmitDisabled'].map(k => [k,c.get(k)]);
        }"""), flush=True)
    forward.click()

    stack = page.locator("#select-stack")
    stack.locator(".nav-tabs").get_by_text("BIGTOP-3.3.0", exact=True).click()
    version = stack.locator(".details-panel .dropdown-toggle")
    if not re.search(r"3\.3\.0", version.inner_text()):
        version.click()
        stack.locator(".details-panel .dropdown-menu a").filter(
            has_text=re.compile(r"3\.3\.0")
        ).first.click()
    expect(version).to_contain_text("3.3.0")
    stack.get_by_text("Use Local Repository", exact=True).click()
    form = stack.locator("#repoVersionInfoForm")
    os_rows = form.locator("tr").filter(has=page.locator("td > table.inner-table"))
    redhat = os_rows.filter(has=page.get_by_text("redhat7", exact=True))
    if not redhat.count():
        form.locator(".add-os-button").click()
        form.get_by_role("link", name="redhat7", exact=True).click()
    others = os_rows.filter(has_not=page.get_by_text("redhat7", exact=True))
    while others.count():
        others.first.locator(".remove-icon").click()
    url = redhat.locator(".repo-url input")
    expect(url).to_have_count(1)
    url.press("ControlOrMeta+a")
    url.press_sequentially(repo, delay=10)
    url.press("Tab")
    shot("02-bigtop-redhat7-repository")
    forward.click()

    modal = page.locator(".modal:visible")
    host_names = page.locator("#host-names")
    jdk = modal.filter(has_text="Unsupported JDK")
    host_names.or_(jdk).first.wait_for(timeout=120000)
    if jdk.is_visible():
        jdk.get_by_role("button", name="Proceed Anyway").click()
    host_names.fill("\n".join(hosts))
    manual = page.locator(".radio-button-options .row").filter(has_text="manual registration")
    if not manual.locator("input[type=radio]").is_checked():
        manual.locator("label").click()
        warning = modal.filter(has_text="manually install")
        warning.get_by_role("button", name="OK", exact=True).click()
    shot("03-manual-registration")
    forward.click()
    modal.filter(has_text="Before You Proceed").get_by_role("button", name="OK", exact=True).click()

    table = page.locator("#confirm-hosts-table")
    for host in hosts:
        row = table.locator("tbody tr").filter(has=page.get_by_text(host, exact=True))
        expect(row.locator(".step3-table-status")).to_contain_text(
            re.compile("Success|Registered", re.I), timeout=300000
        )
    expect(forward).to_be_enabled(timeout=300000)
    shot("04-confirm-hosts")
    forward.click()
    services = page.locator("#step4")
    host_warning = modal.filter(has_text="Host Check Warning")
    services.or_(host_warning).first.wait_for(timeout=90000)
    if host_warning.is_visible():
        shot("04-host-check-warning")
        host_warning.locator(".modal-footer button.btn-warning, .modal-footer button.btn-success").click()
    services.wait_for(timeout=90000)
    shot("05-select-services")
