#!/usr/bin/env python3
"""Idempotent App Store Connect listing finisher for Tailscode.

Reads docs/asc-metadata.json and pushes the decided listing: categories,
name/subtitle/privacy URL (appInfoLocalization), description/keywords/promo/
URLs (the 1.0 version localization), MANUAL release, review details (demo
instructions), free price, China-mainland availability off, and a fully-NONE
age rating. Re-runnable.

IAPs are scripts/asc-products.py; screenshots are scripts/asc-screenshots.py.

Usage: python3 scripts/asc-setup.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.expanduser("~/Dev/operator/lib"))
import asc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(ROOT, "docs/asc-metadata.json")))
APP_ID = spec["appId"]


def first(path, **params):
    return asc.get(path, **params).get("data", [])


def editable_version():
    vers = first(f"/v1/apps/{APP_ID}/appStoreVersions")
    return next(v for v in vers if v["attributes"].get("appStoreState") in
                ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"))


def push_listing():
    info = first(f"/v1/apps/{APP_ID}/appInfos")[0]
    asc.patch(f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"],
        "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": spec["primaryCategory"]}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": spec["secondaryCategory"]}}}}})
    print(f"categories → {spec['primaryCategory']} / {spec['secondaryCategory']}")

    ilocs = first(f"/v1/appInfos/{info['id']}/appInfoLocalizations")
    iloc = next(l["id"] for l in ilocs if l["attributes"].get("locale") == "en-US")
    asc.patch(f"/v1/appInfoLocalizations/{iloc}", {"data": {"type": "appInfoLocalizations",
        "id": iloc, "attributes": {
            "name": spec["name"], "subtitle": spec["subtitle"],
            "privacyPolicyUrl": spec["privacyPolicyUrl"]}}})
    print(f"name/subtitle/privacy set ({iloc})")

    ver = editable_version()
    asc.patch(f"/v1/appStoreVersions/{ver['id']}", {"data": {"type": "appStoreVersions",
        "id": ver["id"], "attributes": {"releaseType": "MANUAL"}}})
    vlocs = first(f"/v1/appStoreVersions/{ver['id']}/appStoreVersionLocalizations")
    vloc = next(l["id"] for l in vlocs if l["attributes"].get("locale") == "en-US")
    asc.patch(f"/v1/appStoreVersionLocalizations/{vloc}", {"data": {
        "type": "appStoreVersionLocalizations", "id": vloc, "attributes": {
            "description": spec["description"], "keywords": spec["keywords"],
            "promotionalText": spec["promotionalText"],
            "supportUrl": spec["supportUrl"], "marketingUrl": spec["marketingUrl"]}}})
    print(f"version {ver['attributes'].get('versionString')} localization set; release=MANUAL")
    return ver["id"]


def push_review_details(ver_id):
    """contactPhone is required by the API; reuse the one already on file from
    another of the team's apps rather than duplicating it into the repo."""
    existing = asc.get(f"/v1/appStoreVersions/{ver_id}/appStoreReviewDetail").get("data")
    attrs = {
        "contactFirstName": spec["contactFirstName"],
        "contactLastName": spec["contactLastName"],
        "contactEmail": spec["contactEmail"],
        "demoAccountRequired": False,
        "notes": spec["reviewNotes"],
    }
    if existing:
        asc.patch(f"/v1/appStoreReviewDetails/{existing['id']}", {"data": {
            "type": "appStoreReviewDetails", "id": existing["id"], "attributes": attrs}})
        print("review details updated")
        return
    phone = None
    for app in ["6779927672", "6785542220", "6787688416"]:
        for v in asc.get(f"/v1/apps/{app}/appStoreVersions", limit=3).get("data", []):
            d = asc.get(f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail").get("data")
            if d and d["attributes"].get("contactPhone"):
                phone = d["attributes"]["contactPhone"]
                break
        if phone:
            break
    if not phone:
        print("! no contact phone found on any sibling app — set review details in web UI")
        return
    attrs["contactPhone"] = phone
    asc.post("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails",
        "attributes": attrs, "relationships": {"appStoreVersion": {
            "data": {"type": "appStoreVersions", "id": ver_id}}}}})
    print("review details set (demo instructions; phone reused from sibling app)")


def push_free_price():
    pts = asc.get(f"/v1/apps/{APP_ID}/appPricePoints",
                  **{"filter[territory]": "USA",
                     "fields[appPricePoints]": "customerPrice", "limit": "200"}).get("data", [])
    free = next(p for p in pts if p["attributes"].get("customerPrice") == "0.0")
    asc.post("/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules",
        "relationships": {
            "app": {"data": {"type": "apps", "id": APP_ID}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${p}"}]}},
        }, "included": [{"type": "appPrices", "id": "${p}",
            "attributes": {"startDate": None},
            "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]})
    print("price → Free (auto-equalizes worldwide)")


def push_availability_minus_china():
    territories = []
    url = "/v1/territories?limit=200"
    page = asc.get(url)
    territories += [t["id"] for t in page.get("data", [])]
    nxt = page.get("links", {}).get("next")
    while nxt:
        page = asc.req("GET", "", raw_url=nxt)
        territories += [t["id"] for t in page.get("data", [])]
        nxt = page.get("links", {}).get("next")
    included = [{"type": "territoryAvailabilities", "id": f"${{t{i}}}",
                 "attributes": {"available": t != "CHN"},
                 "relationships": {"territory": {"data": {"type": "territories", "id": t}}}}
                for i, t in enumerate(territories)]
    asc.post("/v2/appAvailabilities", {"data": {"type": "appAvailabilities",
        "attributes": {"availableInNewTerritories": True},
        "relationships": {
            "app": {"data": {"type": "apps", "id": APP_ID}},
            "territoryAvailabilities": {"data": [
                {"type": "territoryAvailabilities", "id": f"${{t{i}}}"}
                for i in range(len(territories))]}},
        }, "included": included})
    print(f"availability → {len(territories) - 1} territories (China mainland off)")


def push_age_rating():
    """The 2025 questionnaire lives on the appInfo, not the appStoreVersion."""
    info = first(f"/v1/apps/{APP_ID}/appInfos")[0]
    decl = asc.get(f"/v1/appInfos/{info['id']}/ageRatingDeclaration").get("data")
    if not decl:
        print("! no ageRatingDeclaration resource — set in web UI")
        return
    wanted = {
        "advertising": False,
        "alcoholTobaccoOrDrugUseOrReferences": "NONE",
        "contests": "NONE",
        "gambling": False,
        "gamblingSimulated": "NONE",
        "gunsOrOtherWeapons": "NONE",
        "healthOrWellnessTopics": False,
        "lootBox": False,
        "medicalOrTreatmentInformation": "NONE",
        "messagingAndChat": False,
        "parentalControls": False,
        "profanityOrCrudeHumor": "NONE",
        "ageAssurance": False,
        "sexualContentGraphicAndNudity": "NONE",
        "sexualContentOrNudity": "NONE",
        "socialMedia": False,
        "socialMediaAgeRestricted": False,
        "horrorOrFearThemes": "NONE",
        "matureOrSuggestiveThemes": "NONE",
        "unrestrictedWebAccess": False,
        "userGeneratedContent": False,
        "violenceCartoonOrFantasy": "NONE",
        "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        "violenceRealistic": "NONE",
    }
    present = decl.get("attributes", {})
    attrs = {k: v for k, v in wanted.items() if k in present}
    asc.patch(f"/v1/ageRatingDeclarations/{decl['id']}", {"data": {
        "type": "ageRatingDeclarations", "id": decl["id"], "attributes": attrs}})
    print(f"age rating set ({len(attrs)} fields)")


def main():
    ver_id = push_listing()
    push_review_details(ver_id)
    push_free_price()
    push_availability_minus_china()
    push_age_rating()
    print("DONE")


if __name__ == "__main__":
    main()
