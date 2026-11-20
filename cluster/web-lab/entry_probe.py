"""Discover the stack choices presented by a fresh Ambari installation."""
import re

def initial(page, base, hosts, repo, shot):
    page.locator('input[type=text]:visible').first.fill('admin')
    page.locator('input[type=password]:visible').fill('admin')
    page.get_by_role('button', name=re.compile('Sign In', re.I)).click()
    page.get_by_text(re.compile('Launch Install Wizard', re.I)).first.click()
    page.locator('input[type=text]:visible').first.fill('weblab')
    page.get_by_text(re.compile('^Next$', re.I)).last.click()
    page.wait_for_timeout(5000)
    shot('01-stack-discovery')
    raise RuntimeError('Inspect available BIGTOP version and repository choices')
