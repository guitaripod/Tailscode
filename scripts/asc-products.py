#!/usr/bin/env python3
"""Idempotent creation of Tailscode's four IAPs in ASC.

Tailscode Pro (non-consumable, Family Sharing on) + three tip consumables,
matching Tailscode.storekit and ProStore.swift exactly. Each gets an en-US
localization, a USD base price, and a review screenshot. Products stay
MISSING_METADATA until they ride the first version submission — normal.

Usage: python3 scripts/asc-products.py

DEPRECATION (Apple, 2026-07-15): the `inAppPurchaseLocalizations` and
`inAppPurchaseAppStoreReviewScreenshots` (IAP images) resources used below are
deprecated in favor of v2 resources under the new `InAppPurchaseVersion` parent,
with submission via v2 endpoints on `InAppPurchaseV2`. They still work today but
will be removed "in an upcoming release" — migrate before then. `/v2/inAppPurchases`
(creation) is unaffected. TODO: move localization + review-screenshot writes to the
InAppPurchaseVersion endpoints.
"""
import hashlib
import os
import sys

import requests

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

APP = "6791660932"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REVIEW_SHOT = os.path.join(ROOT, "marketing/appstore/iap-review.png")

PRODUCTS = [
    ("com.guitaripod.tailscode.pro", "NON_CONSUMABLE", True, "Tailscode Pro",
     "Tailscode Pro", "Unlimited servers & Live Activities. One-time unlock.", 14.99),
    ("com.guitaripod.tailscode.tip.small", "CONSUMABLE", False, "Tip Small",
     "Small Tip", "A coffee for the developer. Thank you!", 2.99),
    ("com.guitaripod.tailscode.tip.medium", "CONSUMABLE", False, "Tip Medium",
     "Generous Tip", "Serious fuel for development. Thank you!", 9.99),
    ("com.guitaripod.tailscode.tip.large", "CONSUMABLE", False, "Tip Large",
     "Lavish Tip", "You are the reason this app exists. Thank you!", 19.99),
]


def existing_iaps():
    return asc.get(f"/v1/apps/{APP}/inAppPurchasesV2", limit=200).get("data", [])


def closest_point(points, target):
    best, bestd = None, 1e18
    for p in points:
        try:
            price = float(p["attributes"].get("customerPrice"))
        except (TypeError, ValueError):
            continue
        d = abs(price - target)
        if d < bestd:
            best, bestd = p, d
    return best


def try_(label, fn):
    try:
        fn()
        return True
    except Exception as e:
        print(f"    ! {label}: {str(e)[:180]}")
        return False


def upload_review_screenshot(iap_id):
    existing = asc.get(f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot").get("data")
    if existing:
        print("    review screenshot exists")
        return
    data = open(REVIEW_SHOT, "rb").read()
    reserve = asc.post("/v1/inAppPurchaseAppStoreReviewScreenshots", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots",
        "attributes": {"fileName": "iap-review.png", "fileSize": len(data)},
        "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}})
    shot_id = reserve["data"]["id"]
    for op in reserve["data"]["attributes"]["uploadOperations"]:
        headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        requests.request(op["method"], op["url"], headers=headers, data=chunk, timeout=120).raise_for_status()
    asc.patch(f"/v1/inAppPurchaseAppStoreReviewScreenshots/{shot_id}", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots", "id": shot_id,
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print("    + review screenshot")


def ensure_iap(product_id, iap_type, family, ref, display, description, price):
    by_pid = {i["attributes"]["productId"]: i for i in existing_iaps()}
    if product_id in by_pid:
        iap_id = by_pid[product_id]["id"]
        print(f"  ✓ exists {product_id}")
    else:
        r = asc.post("/v2/inAppPurchases", {"data": {"type": "inAppPurchases", "attributes": {
            "name": ref, "productId": product_id, "inAppPurchaseType": iap_type,
            "familySharable": family},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
        iap_id = r["data"]["id"]
        print(f"  + created {product_id} ({iap_type}, ${price}, familySharable={family})")
    try_("localization", lambda: asc.post("/v1/inAppPurchaseLocalizations", {"data": {
        "type": "inAppPurchaseLocalizations",
        "attributes": {"locale": "en-US", "name": display, "description": description},
        "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}}}}))
    pts = asc.get(f"/v2/inAppPurchases/{iap_id}/pricePoints",
                  **{"filter[territory]": "USA", "limit": "200"}).get("data", [])
    pt = closest_point(pts, price)
    if pt:
        try_("price", lambda: asc.post("/v1/inAppPurchasePriceSchedules", {
            "data": {"type": "inAppPurchasePriceSchedules", "relationships": {
                "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${p}"}]}}},
            "included": [{"type": "inAppPurchasePrices", "id": "${p}",
                "attributes": {"startDate": None},
                "relationships": {"inAppPurchasePricePoint": {
                    "data": {"type": "inAppPurchasePricePoints", "id": pt["id"]}}}}]}))
    else:
        print("    ! no USA price point found")
    try_("screenshot", lambda: upload_review_screenshot(iap_id))
    try_("availability", lambda: ensure_availability(iap_id))
    return iap_id


def all_territories_minus_china():
    """Every App Store territory except China mainland — matches the app's own
    availability, and is REQUIRED: an IAP with zero territories stays
    MISSING_METADATA and can't ride a submission."""
    terrs, page = [], asc.get("/v1/territories?limit=200")
    terrs += [t["id"] for t in page["data"]]
    nxt = page.get("links", {}).get("next")
    while nxt:
        page = asc.req("GET", "", raw_url=nxt)
        terrs += [t["id"] for t in page["data"]]
        nxt = page.get("links", {}).get("next")
    return [t for t in terrs if t != "CHN"]


def ensure_availability(iap_id):
    existing = asc.get(f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability").get("data")
    if existing:
        return
    data = [{"type": "territories", "id": t} for t in all_territories_minus_china()]
    asc.post("/v1/inAppPurchaseAvailabilities", {"data": {
        "type": "inAppPurchaseAvailabilities",
        "attributes": {"availableInNewTerritories": True},
        "relationships": {
            "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
            "availableTerritories": {"data": data}}}})


def main():
    print("Tailscode IAPs:")
    for product_id, iap_type, family, ref, display, description, price in PRODUCTS:
        ensure_iap(product_id, iap_type, family, ref, display, description, price)
    print("DONE")


if __name__ == "__main__":
    main()
