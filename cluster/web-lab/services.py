"""Exercise steps 4–10 of the BIGTOP cluster installer in Chromium."""
import re

from playwright.sync_api import expect


SERVICES = {"HDFS", "YARN", "MAPREDUCE2", "TEZ", "HIVE", "SPARK", "ZOOKEEPER"}
JDBC = "jdbc:postgresql://pg.lab.test:5432/hive?sslmode=verify-full&sslrootcert=/etc/pki/bigtop/ca.crt"
NEXT = '.wizard-footer [data-qa="wizard-next"]'


def names(label):
    return {s.strip().upper() for s in label.split("+")}


def advance(page, destination, allowed=()):
    """Answer only anticipated wizard modals and surface any other decision."""
    page.locator(NEXT).click(timeout=90000)
    modal = page.locator("#modal:visible").last
    for _ in range(10):
        page.locator(f"{destination}:visible, #modal:visible").first.wait_for(timeout=120000)
        if page.locator(destination).is_visible() and not modal.is_visible():
            return
        title = modal.locator(".modal-header h4").inner_text().strip()
        primary = modal.locator('[data-qa="modal-primary"]')
        caption = primary.inner_text().strip()
        if (title.casefold(), caption.casefold()) not in {(t.casefold(), c.casefold()) for t, c in allowed}:
            raise RuntimeError(f"Unexpected installer decision {title!r} / {caption!r}")
        primary.click()
        page.wait_for_timeout(350)
    raise RuntimeError(f"Wizard did not reach {destination}")


def select_services(page):
    rows = page.locator('#step4 [data-qa="service-row"]')
    rows.first.wait_for()
    selected = set()
    for row in rows.all():
        label = row.locator('[data-qa="service-name"]')
        group = names(label.inner_text())
        wanted = bool(group & SERVICES)
        if wanted and group - SERVICES:
            raise RuntimeError(f"Unexpected bundled services {group}")
        check = row.locator('input[type="checkbox"]')
        if check.is_checked() != wanted:
            label.click()
        expect(check).to_be_checked(checked=wanted)
        if wanted:
            selected.update(group)
    if selected != SERVICES:
        raise RuntimeError(f"Services available for selection: {sorted(selected)}")


def assign_masters(page, hosts):
    rows = page.locator('#assign-masters [data-qa="component-row"]')
    rows.first.wait_for()
    targets = {"NameNode": hosts[0], "ResourceManager": hosts[1], "HiveServer2": hosts[2],
               "Hive Metastore": hosts[2], "History Server": hosts[1]}
    for role, host in targets.items():
        row = rows.filter(has=page.locator('[data-qa="component-name"]',
                                           has_text=re.compile(rf"^\s*{re.escape(role)}:\s*$")))
        dropdown = row.locator("button.dropdown-toggle")
        if row.locator(".hostName").count():
            expect(row.locator(".hostName")).to_contain_text(host)
        else:
            dropdown.click()
            row.locator(".dropdown-item").filter(has_text=host).click()
            expect(dropdown).to_contain_text(host)

    zk = rows.filter(has=page.locator('[data-qa="component-name"]', has_text="ZooKeeper Server"))
    while zk.count() < len(hosts):
        count = zk.count()
        zk.locator(".ZOOKEEPER_SERVER-add").last.click()
        expect(zk).to_have_count(count + 1)
    assignments = zk.locator(".selected-item").all_inner_texts()
    if len(assignments) != len(hosts) or not all(any(host in s for s in assignments) for host in hosts):
        raise RuntimeError(f"Unexpected ZooKeeper quorum {assignments}")


def set_field(scope, name, value):
    field = scope.locator(f'input[data-qa="{name}"]:visible').first
    if field.input_value() != value:
        field.fill(value)
        field.press("Tab")
    expect(field).to_have_value(value)


def configure_hive(page, password, shot):
    credentials = page.locator("#credentials .credentials-table")
    row = credentials.locator("tbody tr").filter(has_text="Hive Database")
    row.wait_for(timeout=120000)
    set_field(row, "javax.jdo.option.ConnectionUserName", "hive_catalog")
    passwords = row.locator('input[type="password"]')
    expect(passwords).to_have_count(2)
    try:
        for field in passwords.all():
            field.fill(password)
            field.press("Tab")
    except Exception:
        # Playwright call logs can include the argument passed to fill().
        raise RuntimeError("Could not complete the Hive credential fields") from None
    advance(page, "#databases")
    db = page.locator("#databases")
    combo = db.locator('.combo-widget[data-qa="hive_database"]')
    combo.locator(".dropdown-toggle").click()
    combo.get_by_text("Existing PostgreSQL", exact=True).click()
    expect(combo.locator(".config-groups-dropdown input")).to_have_value("Existing PostgreSQL")
    set_field(db, "ambari.hive.db.schema.name", "hive")
    set_field(db, "javax.jdo.option.ConnectionUserName", "hive_catalog")
    set_field(db, "javax.jdo.option.ConnectionDriverName", "org.postgresql.Driver")
    set_field(db, "javax.jdo.option.ConnectionURL", JDBC)
    test = db.locator(".db-connection")
    test.locator(".btn-primary:not(.disabled)").click()
    result = test.locator(".connection-result a")
    expect(result).to_have_text("Connection OK", timeout=180000)
    expect(db.locator('input[data-qa="javax.jdo.option.ConnectionURL"]:visible')).to_have_value(JDBC)
    shot("07-database-connected")
    advance(page, "#directories")
    advance(page, 'input[data-qa="hdfs_user"]')
    accounts = page.locator("#serviceConfig")
    for prop, account in {"hdfs_user": "hdfs", "yarn_user": "yarn", "mapred_user": "mapred",
                          "hive_user": "hive", "zk_user": "zookeeper", "spark_user": "spark"}.items():
        expect(accounts.locator(f'input[data-qa="{prop}"]')).to_have_value(account)
    shot("07-service-accounts")
    advance(page, "#all-configurations")


def services(page, hosts, db_password, shot):
    select_services(page)
    shot("04-services")
    advance(page, "#assign-masters", {("Limited Functionality Warning", "Proceed Anyway")})
    assign_masters(page, hosts)
    shot("05-masters")
    advance(page, "#step6", {("Validation Issues", "Continue Anyway")})
    table = page.locator("#component_assign_table")
    for role in ("DATANODE", "NODEMANAGER", "CLIENT"):
        table.locator(f"#all-{role}").click()
        for host in hosts:
            row = table.locator("tbody tr").filter(has_text=host)
            expect(row.locator(f'td.{role} input')).to_be_checked()
    shot("06-workers-clients")
    advance(page, "#serviceConfig", {("Validation Issues", "Continue Anyway")})
    configure_hive(page, db_password, shot)
    advance(page, "#deploy-review", {("Configurations", "Proceed Anyway")})
    labels = page.locator("#step8-content .service-name")
    labels.first.wait_for()
    reviewed = set().union(*(names(s) for s in labels.all_inner_texts()))
    if reviewed != SERVICES:
        raise RuntimeError(f"Unexpected services in deployment review {sorted(reviewed)}")
    shot("08-review")
    page.locator(NEXT).click()
    page.wait_for_url("**/#/installer/step9", timeout=180000)
    page.locator("#deploy").wait_for(timeout=120000)
    shot("09-install")
    result = page.locator('#deploy p[data-qa^="deploy-result-"]')
    result.wait_for(timeout=45 * 60 * 1000)
    if result.inner_text().strip() != "Successfully installed and started the services.":
        raise RuntimeError(f"Ambari installation ended with {result.inner_text().strip()}")
    shot("09-started")
    advance(page, "#deploy-summary")
    page.locator("#step10-content li").first.wait_for()
    shot("10-summary")
    page.locator(NEXT).click()
    page.locator("#deploy-summary").wait_for(state="detached", timeout=90000)
