#!/usr/bin/env python3
"""scripts/app-store-connect.py 的单元测试（只用自带的库，不联网）。

用法: python3 -m unittest discover -s scripts -p 'test_*.py'

同步的测试用一个假的 App Store Connect：事先准备好每个 GET 的返回，记下脚本发出的每个请求，
再检查写了什么（POST / PATCH / DELETE / PUT）。
"""
import base64
import contextlib
import datetime
import hashlib
import importlib.util
import io
import json
import shutil
import struct
import subprocess
import tempfile
import unittest
import urllib.parse
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("app_store_connect", HERE / "app-store-connect.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

BASE = asc.API_BASE
TODAY = datetime.date(2026, 10, 1)
TERRITORIES = ["USA", "CHN", "HKG", "MAC", "TWN", "JPN"]
CONTACT = {"contactFirstName": "Wei", "contactLastName": "Hu", "contactPhone": "+86 138 0000 0000", "contactEmail": "a@example.com"}
HAS_OPENSSL = shutil.which("openssl") is not None


# ---------------------------------------------------------------- 测试用的图片


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def png(width, height, color_type=2, fill=0, trns=False):
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    row = b"\x00" + bytes([fill]) * (width * channels)
    body = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0))
    if trns:
        body += chunk(b"tRNS", b"\x00\x00\x00\x00\x00\x00")
    body += chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b"")
    return b"\x89PNG\r\n\x1a\n" + body


def jpeg(width, height):
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, height, width, 3) + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    # SOF 前面多一个 0xFF 填充字节。
    return b"\xff\xd8" + app0 + b"\xff" + sof + b"\xff\xd9"


# ---------------------------------------------------------------- 假的 App Store Connect


def res(kind, rid, rels=None, **attributes):
    resource = {"type": kind, "id": rid, "attributes": attributes}
    if rels is not None:
        resource["relationships"] = {name: {"data": data} for name, data in rels.items()}
    return resource


def page(*items, next_url=None, included=()):
    body = {"data": list(items), "links": {"self": "x"}}
    if next_url:
        body["links"]["next"] = next_url
    if included:
        body["included"] = list(included)
    return body


def single(resource):
    return {"data": resource}


NOT_FOUND = (404, {"errors": [{"status": "404", "code": "NOT_FOUND", "title": "The specified resource does not exist"}]})


class FakeApple:
    def __init__(self):
        self.gets = {}
        self.handlers = {}
        self.calls = []
        self.counter = 0

    def get(self, path, *responses):
        """准备 GET 的返回：给几个就按顺序返回，最后一个一直重复。返回是 dict（200）或者 (状态码, dict)。"""
        self.gets[path] = [r if isinstance(r, tuple) else (200, r) for r in responses]

    def on(self, method, path, handler):
        self.handlers[(method, path)] = handler

    def send(self, method, url, headers, body):
        parts = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parts.query))
        payload = body
        if body is not None and headers.get("Content-Type") == "application/json":
            payload = json.loads(body)
        self.calls.append({"method": method, "host": parts.netloc, "path": parts.path, "query": query,
                           "payload": payload, "headers": headers})
        if (method, parts.path) in self.handlers:
            status, response = self.handlers[(method, parts.path)](query, payload)
            return status, json.dumps(response).encode() if response is not None else b""
        if method == "GET":
            if parts.path not in self.gets:
                raise AssertionError(f"测试没有准备 GET {parts.path}")
            responses = self.gets[parts.path]
            status, response = responses.pop(0) if len(responses) > 1 else responses[0]
            return status, json.dumps(response).encode()
        if method in ("DELETE", "PUT"):
            return 204, b""
        data = payload.get("data") if isinstance(payload, dict) else None
        if isinstance(data, dict):
            self.counter += 1
            resource = {"type": data.get("type"), "id": data.get("id") or f"new-{self.counter}",
                        "attributes": data.get("attributes") or {}}
            return (201 if method == "POST" else 200), json.dumps({"data": resource}).encode()
        return 204, b""

    def writes(self):
        return [(c["method"], c["path"]) for c in self.calls if c["method"] != "GET"]

    def payload(self, method, path):
        found = [c["payload"] for c in self.calls if c["method"] == method and c["path"] == path]
        if len(found) != 1:
            raise AssertionError(f"{method} {path} 发了 {len(found)} 次：{self.writes()}")
        return found[0]


def age_rating(value_for_levels, value_for_flags):
    attributes = {key: value_for_levels for key in asc.AGE_RATING_LEVELS}
    attributes.update({key: value_for_flags for key in asc.AGE_RATING_FLAGS})
    attributes.update(kidsAgeBand=None, ageRatingOverrideV2="NONE", koreaAgeRatingOverride="NONE",
                      developerAgeRatingInfoUrl=None)
    return attributes


def synced(fake, listing, version="0.48.0", version_id="v1", screenshots=()):
    """App Store Connect 上已经和资料完全一样（第一个版本，准备提交）。各个测试在这个基础上改。"""
    config = listing.config
    fake.get("/v1/apps", page(res("apps", "app1", bundleId=asc.BUNDLE_ID, name="Stox – Menu Bar Stocks",
                                  primaryLocale="en-US", contentRightsDeclaration=config["contentRightsDeclaration"])))
    fake.get("/v1/apps/app1/appStoreVersions", page(res(
        "appStoreVersions", version_id, platform="MAC_OS", versionString=version, appVersionState="PREPARE_FOR_SUBMISSION",
        appStoreState="PREPARE_FOR_SUBMISSION", copyright=listing.copyright, releaseType=config["releaseType"])))
    fake.get("/v1/apps/app1/appPriceSchedule", single(res("appPriceSchedules", "sched1")))
    fake.get("/v1/appPriceSchedules/sched1/manualPrices", page(
        res("appPrices", "price1", rels={"appPricePoint": {"type": "appPricePoints", "id": "pp-0"},
                                         "territory": {"type": "territories", "id": "USA"}}, manual=True, startDate=None),
        included=[res("appPricePoints", "pp-0", customerPrice="0.0", proceeds="0.0")]))
    fake.get("/v1/apps/app1/appAvailabilityV2", single(res("appAvailabilities", "avail1", availableInNewTerritories=True)))
    fake.get("/v2/appAvailabilities/avail1/territoryAvailabilities", page(*[
        res("territoryAvailabilities", f"ta-{t}", rels={"territory": {"type": "territories", "id": t}}, available=t != "CHN")
        for t in TERRITORIES]))
    fake.get("/v1/apps/app1/appInfos", page(res(
        "appInfos", "info1", rels={"primaryCategory": {"type": "appCategories", "id": "FINANCE"},
                                   "secondaryCategory": {"type": "appCategories", "id": "PRODUCTIVITY"}},
        state="PREPARE_FOR_SUBMISSION")))
    fake.get("/v1/appInfos/info1/appInfoLocalizations", page(*[
        res("appInfoLocalizations", f"ail-{locale}", locale=locale, **{k: f[k] for k in asc.APP_INFO_FIELDS})
        for locale, f in listing.locales.items()]))
    fake.get("/v1/appInfos/info1/ageRatingDeclaration", single(res("ageRatingDeclarations", "age1", **age_rating("NONE", False))))
    fake.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations", page(*[
        res("appStoreVersionLocalizations", f"avl-{locale}", locale=locale, whatsNew=None,
            **{k: f[k] for k in asc.VERSION_FIELDS})
        for locale, f in listing.locales.items()]))
    fake.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail", single(res(
        "appStoreReviewDetails", "review1", notes=listing.review_notes, demoAccountRequired=False,
        demoAccountName=None, demoAccountPassword=None, **CONTACT)))
    fake.get(f"/v1/appStoreVersions/{version_id}/relationships/build", {"data": {"type": "builds", "id": "b1"}})
    fake.get("/v1/builds", page(res("builds", "b1", version="612.3", processingState="VALID",
                                    usesNonExemptEncryption=False, uploadedDate="2026-10-01T00:00:00Z")))
    fake.get("/v1/appStoreVersionLocalizations/avl-en-US/appScreenshotSets", page(
        res("appScreenshotSets", "set1", screenshotDisplayType="APP_DESKTOP")))
    fake.get("/v1/appScreenshotSets/set1/appScreenshots", page(*[
        res("appScreenshots", f"shot{i}", fileName=path.name, sourceFileChecksum=asc.md5(path),
            assetDeliveryState={"state": "COMPLETE", "errors": []})
        for i, path in enumerate(screenshots)]))
    fake.get("/v1/apps/app1/reviewSubmissions", page())


class SyncTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.root = self.tmp / "listing"
        shutil.copytree(asc.LISTING, self.root)
        self.changelog = self.tmp / "CHANGELOG.md"
        self.changelog.write_text("# 更新日志\n\n## 0.49.0\n\n- 新功能 `stox-cli`，见 [说明](https://example.com)。\n\n## 0.48.0\n\n- 旧的\n",
                                  encoding="utf-8")
        self.fake = FakeApple()
        self.sleeps = []

    def listing(self, version, screenshots=None):
        listing = asc.Listing(self.root, self.changelog, today=TODAY).load(version, screenshots)
        self.assertEqual(listing.errors, [])
        return listing

    def sync(self, listing, version, dry_run=False, **options):
        api = asc.Api(lambda: "test-token", send=self.fake.send, dry_run=dry_run, sleep=self.sleeps.append)
        clock = iter(range(0, 100000, 30))
        sync = asc.Sync(api, listing, version, sleep=self.sleeps.append, clock=lambda: next(clock), **options)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            sync.run()
        return output.getvalue()

    def screenshot_dir(self, count):
        folder = self.tmp / "shots"
        folder.mkdir()
        for i in range(count):
            (folder / f"{i + 1}-shot.png").write_bytes(png(1440, 900, fill=i + 1))
        return folder


class SyncTests(SyncTestCase):
    def test_nothing_to_write_when_already_in_sync(self):
        folder = self.screenshot_dir(2)
        listing = self.listing("0.48.0", folder)
        synced(self.fake, listing, screenshots=listing.screenshots)
        output = self.sync(listing, "0.48.0", attach_latest=True, contact=CONTACT)
        self.assertEqual(self.fake.writes(), [])
        self.assertIn("什么都没改", output)
        for call in self.fake.calls:
            self.assertEqual(call["headers"]["Authorization"], "Bearer test-token")

    def test_placeholders_of_a_new_app(self):
        # 真的 App Store Connect 上，没定过价、没设过销售范围的新 App 也会返回一个和 App 同 ID 的空壳，
        # 再往下读它的价格、地区是 404（“There is no resource of type 'null' with id …”）。
        listing = self.listing("0.48.0")
        fake = self.fake
        synced(fake, listing)
        fake.get("/v1/apps/app1/appPriceSchedule", single(res("appPriceSchedules", "app1")))
        fake.get("/v1/appPriceSchedules/app1/manualPrices", NOT_FOUND)
        fake.get("/v1/apps/app1/appPricePoints", page(res("appPricePoints", "pp-0", customerPrice="0.0")))
        fake.get("/v1/apps/app1/appAvailabilityV2", single(res("appAvailabilities", "app1", availableInNewTerritories=None)))
        fake.get("/v2/appAvailabilities/app1/territoryAvailabilities", NOT_FOUND)
        fake.get("/v1/territories", page(*[res("territories", t, currency="X") for t in TERRITORIES]))
        fake.get("/v1/appStoreVersions/v1/appStoreReviewDetail", single(res("appStoreReviewDetails", "v1", notes=None)))
        fake.on("PATCH", "/v1/appStoreReviewDetails/v1", lambda q, p: NOT_FOUND)

        self.sync(listing, "0.48.0", attach_latest=True, contact=CONTACT)

        price = fake.payload("POST", "/v1/appPriceSchedules")
        self.assertEqual(price["included"][0]["relationships"]["appPricePoint"]["data"]["id"], "pp-0")
        availability = fake.payload("POST", "/v2/appAvailabilities")
        territories = {item["relationships"]["territory"]["data"]["id"]: item["attributes"]["available"]
                       for item in availability["included"]}
        self.assertEqual(territories, {t: t != "CHN" for t in TERRITORIES})
        self.assertNotIn("PATCH", [m for m, path in fake.writes() if "territoryAvailabilities" in path])
        review = fake.payload("POST", "/v1/appStoreReviewDetails")["data"]
        self.assertEqual(review["attributes"]["contactEmail"], CONTACT["contactEmail"])
        self.assertEqual(review["relationships"]["appStoreVersion"]["data"]["id"], "v1")

    def test_first_version_of_a_new_app(self):
        listing = self.listing("0.48.0")
        fake = self.fake
        synced(fake, listing)
        fake.get("/v1/apps", page(res("apps", "app1", bundleId=asc.BUNDLE_ID, name="Stox", primaryLocale="en-US",
                                      contentRightsDeclaration=None)))
        # 新建的 App 自带一个“1.0 准备提交”的版本。
        fake.get("/v1/apps/app1/appStoreVersions", page(res(
            "appStoreVersions", "v1", platform="MAC_OS", versionString="1.0", appVersionState="PREPARE_FOR_SUBMISSION",
            copyright=None, releaseType="MANUAL")))
        fake.get("/v1/apps/app1/appPriceSchedule", NOT_FOUND)
        fake.get("/v1/apps/app1/appPricePoints",
                 page(res("appPricePoints", "pp-1", customerPrice="0.99"), next_url=BASE + "/v1/apps/app1/appPricePoints?cursor=2"),
                 page(res("appPricePoints", "pp-0", customerPrice="0.0")))
        fake.get("/v1/apps/app1/appAvailabilityV2", NOT_FOUND)
        fake.get("/v1/territories",
                 page(*[res("territories", t, currency="X") for t in TERRITORIES[:3]], next_url=BASE + "/v1/territories?cursor=3"),
                 page(*[res("territories", t, currency="X") for t in TERRITORIES[3:]]))
        fake.get("/v1/apps/app1/appInfos", page(res("appInfos", "info1", rels={"primaryCategory": None, "secondaryCategory": None},
                                                    state="PREPARE_FOR_SUBMISSION")))
        fake.get("/v1/appInfos/info1/appInfoLocalizations", page(res(
            "appInfoLocalizations", "ail-en-US", locale="en-US", name="Stox", subtitle=None, privacyPolicyUrl=None)))
        fake.get("/v1/appInfos/info1/ageRatingDeclaration", single(res("ageRatingDeclarations", "age1", **age_rating(None, None))))
        fake.get("/v1/appStoreVersions/v1/appStoreVersionLocalizations", page(res(
            "appStoreVersionLocalizations", "avl-en-US", locale="en-US", description=None, keywords=None, whatsNew=None)))
        fake.get("/v1/appStoreVersions/v1/appStoreReviewDetail", NOT_FOUND)
        fake.get("/v1/appStoreVersions/v1/relationships/build", {"data": None})
        fake.get("/v1/builds", page(res("builds", "b1", version="612.3", processingState="VALID", usesNonExemptEncryption=None)))
        fake.on("POST", "/v1/reviewSubmissions", lambda q, p: (201, single(res("reviewSubmissions", "sub1", state="READY_FOR_REVIEW"))))
        fake.get("/v1/reviewSubmissions/sub1/items", page())

        self.sync(listing, "0.48.0", attach_latest=True, submit=True, contact=CONTACT)

        self.assertEqual(fake.payload("PATCH", "/v1/apps/app1")["data"]["attributes"],
                         {"contentRightsDeclaration": "USES_THIRD_PARTY_CONTENT"})
        # 免费：美国的 0 元价格点，跟着 links.next 翻到第二页才找到。
        price = fake.payload("POST", "/v1/appPriceSchedules")
        self.assertEqual(price["data"]["relationships"]["baseTerritory"]["data"]["id"], "USA")
        self.assertEqual(price["included"][0]["relationships"]["appPricePoint"]["data"]["id"], "pp-0")
        self.assertEqual(price["data"]["relationships"]["manualPrices"]["data"][0]["id"], price["included"][0]["id"])
        # 销售范围：只有中国大陆不上架，港澳台照常。
        availability = fake.payload("POST", "/v2/appAvailabilities")
        self.assertTrue(availability["data"]["attributes"]["availableInNewTerritories"])
        territories = {item["relationships"]["territory"]["data"]["id"]: item["attributes"]["available"]
                       for item in availability["included"]}
        self.assertEqual(territories, {t: t != "CHN" for t in TERRITORIES})
        self.assertEqual([r["id"] for r in availability["data"]["relationships"]["territoryAvailabilities"]["data"]],
                         [item["id"] for item in availability["included"]])
        self.assertEqual(len([c for c in fake.calls if c["path"] == "/v1/territories"]), 2)
        # 版本：用新 App 自带的 1.0，改成这个版本号。
        self.assertEqual(fake.payload("PATCH", "/v1/appStoreVersions/v1")["data"]["attributes"],
                         {"versionString": "0.48.0", "copyright": "2026 whrss9527", "releaseType": "AFTER_APPROVAL"})
        self.assertNotIn(("POST", "/v1/appStoreVersions"), fake.writes())
        info = fake.payload("PATCH", "/v1/appInfos/info1")["data"]["relationships"]
        self.assertEqual((info["primaryCategory"]["data"]["id"], info["secondaryCategory"]["data"]["id"]), ("FINANCE", "PRODUCTIVITY"))
        self.assertEqual(fake.payload("PATCH", "/v1/appInfoLocalizations/ail-en-US")["data"]["attributes"], {
            "name": "Stox – Menu Bar Stocks", "subtitle": "Quotes one click away",
            "privacyPolicyUrl": "https://whrss.com/privacy/stox/"})
        zh_info = fake.payload("POST", "/v1/appInfoLocalizations")["data"]
        self.assertEqual(zh_info["attributes"]["locale"], "zh-Hans")
        self.assertEqual(zh_info["relationships"]["appInfo"]["data"]["id"], "info1")
        # 年龄分级：每个程度类问题答 NONE，每个是非题答 false；儿童类别、手动分级这些不动。
        expected = {key: "NONE" for key in asc.AGE_RATING_LEVELS}
        expected.update({key: False for key in asc.AGE_RATING_FLAGS})
        self.assertEqual(fake.payload("PATCH", "/v1/ageRatingDeclarations/age1")["data"]["attributes"], expected)
        # 第一个版本：两种语言都不发 whatsNew。
        en = fake.payload("PATCH", "/v1/appStoreVersionLocalizations/avl-en-US")["data"]["attributes"]
        zh = fake.payload("POST", "/v1/appStoreVersionLocalizations")["data"]["attributes"]
        self.assertNotIn("whatsNew", en)
        self.assertNotIn("whatsNew", zh)
        self.assertEqual(en["keywords"], listing.locales["en-US"]["keywords"])
        self.assertEqual(zh["locale"], "zh-Hans")
        review = fake.payload("POST", "/v1/appStoreReviewDetails")["data"]
        self.assertEqual(review["attributes"], {"notes": listing.review_notes, "demoAccountRequired": False, **CONTACT})
        self.assertEqual(review["relationships"]["appStoreVersion"]["data"]["id"], "v1")
        self.assertEqual(fake.payload("PATCH", "/v1/builds/b1")["data"]["attributes"], {"usesNonExemptEncryption": False})
        self.assertEqual(fake.payload("PATCH", "/v1/appStoreVersions/v1/relationships/build"), {"data": {"type": "builds", "id": "b1"}})
        latest = [c for c in fake.calls if c["path"] == "/v1/builds"][0]["query"]
        self.assertEqual((latest["filter[processingState]"], latest["filter[preReleaseVersion.version]"], latest["sort"]),
                         ("VALID", "0.48.0", "-uploadedDate"))
        # 提交审核：新建审核提交 → 加进这个版本 → 提交，按这个顺序。
        writes = fake.writes()
        self.assertEqual(writes[-3:], [("POST", "/v1/reviewSubmissions"), ("POST", "/v1/reviewSubmissionItems"),
                                       ("PATCH", "/v1/reviewSubmissions/sub1")])
        self.assertEqual(fake.payload("POST", "/v1/reviewSubmissions")["data"]["attributes"], {"platform": "MAC_OS"})
        item = fake.payload("POST", "/v1/reviewSubmissionItems")["data"]["relationships"]
        self.assertEqual((item["reviewSubmission"]["data"]["id"], item["appStoreVersion"]["data"]["id"]), ("sub1", "v1"))
        self.assertEqual(fake.payload("PATCH", "/v1/reviewSubmissions/sub1")["data"]["attributes"], {"submitted": True})
        # 没给截图：截图一个请求都不发。
        self.assertFalse([c for c in fake.calls if "Screenshot" in c["path"]])

    def test_update_with_new_build_and_screenshots(self):
        (self.root / "en-US" / "whats_new").mkdir()
        (self.root / "en-US" / "whats_new" / "0.49.0.txt").write_text("Bug fixes.\n", encoding="utf-8")
        folder = self.screenshot_dir(2)
        listing = self.listing("0.49.0", folder)
        fake = self.fake
        synced(fake, listing, version_id="v2")
        fake.get("/v1/apps/app1/appStoreVersions", page(res(
            "appStoreVersions", "v1", platform="MAC_OS", versionString="0.48.0", appVersionState="READY_FOR_DISTRIBUTION")))
        fake.on("POST", "/v1/appStoreVersions", lambda q, p: (201, single(res("appStoreVersions", "v2", **p["data"]["attributes"]))))
        # 上架后的 App 信息不能改，用准备中的那份。
        fake.get("/v1/apps/app1/appInfos", page(
            res("appInfos", "live", rels={"primaryCategory": None, "secondaryCategory": None}, state="READY_FOR_DISTRIBUTION"),
            res("appInfos", "info1", rels={"primaryCategory": {"type": "appCategories", "id": "FINANCE"},
                                           "secondaryCategory": {"type": "appCategories", "id": "PRODUCTIVITY"}},
                state="PREPARE_FOR_SUBMISSION")))
        fake.get("/v2/appAvailabilities/avail1/territoryAvailabilities", page(*[
            res("territoryAvailabilities", f"ta-{t}", rels={"territory": {"type": "territories", "id": t}},
                available=t not in ("HKG",)) for t in TERRITORIES]))
        fake.get("/v1/appStoreVersions/v2/appStoreReviewDetail", single(None))
        fake.get("/v1/appStoreVersions/v2/relationships/build", {"data": {"type": "builds", "id": "b1"}})
        # 刚上传的构建：先还没出现，然后在处理，最后处理完。
        fake.get("/v1/builds", page(), page(res("builds", "b2", version="613.1", processingState="PROCESSING")),
                 page(res("builds", "b2", version="613.1", processingState="VALID", usesNonExemptEncryption=False)))
        fake.get("/v1/appScreenshotSets/set1/appScreenshots", page(res(
            "appScreenshots", "old", fileName="old.png", sourceFileChecksum="0" * 32, assetDeliveryState={"state": "COMPLETE"})))
        uploads = iter(["s1", "s2"])

        def reserve(query, payload):
            size = payload["data"]["attributes"]["fileSize"]
            half = size // 2
            operations = [
                {"method": "PUT", "url": f"https://upload.example/part1?{size}", "offset": 0, "length": half,
                 "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
                {"method": "PUT", "url": f"https://upload.example/part2?{size}", "offset": half, "length": size - half,
                 "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
            ]
            return 201, single(res("appScreenshots", next(uploads), uploadOperations=operations,
                                   assetDeliveryState={"state": "AWAITING_UPLOAD"}))

        fake.on("POST", "/v1/appScreenshots", reserve)
        for shot in ("s1", "s2"):
            fake.get(f"/v1/appScreenshots/{shot}", single(res("appScreenshots", shot, assetDeliveryState={"state": "UPLOAD_COMPLETE"})),
                     single(res("appScreenshots", shot, assetDeliveryState={"state": "COMPLETE"})))

        output = self.sync(listing, "0.49.0", build="613.1", wait_minutes=60, contact=CONTACT)

        created = fake.payload("POST", "/v1/appStoreVersions")["data"]
        self.assertEqual(created["attributes"], {"platform": "MAC_OS", "versionString": "0.49.0",
                                                 "copyright": "2026 whrss9527", "releaseType": "AFTER_APPROVAL"})
        self.assertEqual(created["relationships"]["app"]["data"]["id"], "app1")
        # 不是第一个版本：发 whatsNew；英文用文件，中文用 CHANGELOG 的这一节（纯文本）。
        en = fake.payload("PATCH", "/v1/appStoreVersionLocalizations/avl-en-US")["data"]["attributes"]
        zh = fake.payload("PATCH", "/v1/appStoreVersionLocalizations/avl-zh-Hans")["data"]["attributes"]
        self.assertEqual(en, {"whatsNew": "Bug fixes."})
        self.assertEqual(zh, {"whatsNew": "• 新功能 stox-cli，见 说明。"})
        # 只改不对的地区：中国大陆被打开了、香港被关掉了。
        self.assertEqual(fake.payload("PATCH", "/v1/territoryAvailabilities/ta-CHN")["data"]["attributes"], {"available": False})
        self.assertEqual(fake.payload("PATCH", "/v1/territoryAvailabilities/ta-HKG")["data"]["attributes"], {"available": True})
        self.assertEqual(len([w for w in fake.writes() if "territoryAvailabilities" in w[1]]), 2)
        self.assertNotIn(("PATCH", "/v1/appInfos/live"), fake.writes())
        self.assertEqual(fake.payload("POST", "/v1/appStoreReviewDetails")["data"]["relationships"]["appStoreVersion"]["data"]["id"], "v2")
        # 截图：删掉旧的，按文件名顺序一张一张传（分两段，带上要求的请求头、不带令牌），传完提交 MD5，等处理完，再排好顺序。
        self.assertIn(("DELETE", "/v1/appScreenshots/old"), fake.writes())
        reservations = [c["payload"]["data"]["attributes"] for c in fake.calls if c["method"] == "POST" and c["path"] == "/v1/appScreenshots"]
        self.assertEqual([r["fileName"] for r in reservations], ["1-shot.png", "2-shot.png"])
        puts = [c for c in fake.calls if c["method"] == "PUT"]
        self.assertEqual(len(puts), 4)
        first = (folder / "1-shot.png").read_bytes()
        self.assertEqual(puts[0]["payload"] + puts[1]["payload"], first)
        for put in puts:
            self.assertEqual(put["host"], "upload.example")
            self.assertEqual(put["headers"], {"Content-Type": "image/png"})
        self.assertEqual(fake.payload("PATCH", "/v1/appScreenshots/s1")["data"]["attributes"],
                         {"uploaded": True, "sourceFileChecksum": hashlib.md5(first).hexdigest()})
        self.assertEqual(fake.payload("PATCH", "/v1/appScreenshotSets/set1/relationships/appScreenshots"),
                         {"data": [{"type": "appScreenshots", "id": "s1"}, {"type": "appScreenshots", "id": "s2"}]})
        # 构建：等了两轮（每轮 30 秒），处理完后选上。
        self.assertIn(30, self.sleeps)
        self.assertIn("构建 613.1：还没出现", output)
        self.assertIn("构建 613.1：PROCESSING", output)
        query = [c for c in fake.calls if c["path"] == "/v1/builds"][0]["query"]
        self.assertEqual((query["filter[version]"], query["filter[preReleaseVersion.version]"],
                          query["filter[preReleaseVersion.platform]"]), ("613.1", "0.49.0", "MAC_OS"))
        self.assertEqual(fake.payload("PATCH", "/v1/appStoreVersions/v2/relationships/build"), {"data": {"type": "builds", "id": "b2"}})
        self.assertNotIn(("PATCH", "/v1/builds/b2"), fake.writes())
        self.assertFalse([w for w in fake.writes() if "reviewSubmission" in w[1]])

    def test_update_without_english_whats_new_stops_before_writing(self):
        listing = self.listing("0.49.0")
        synced(self.fake, listing)
        self.fake.get("/v1/apps/app1/appStoreVersions", page(res(
            "appStoreVersions", "v1", platform="MAC_OS", versionString="0.48.0", appVersionState="READY_FOR_DISTRIBUTION")))
        with self.assertRaises(asc.Failure) as caught:
            self.sync(listing, "0.49.0")
        self.assertIn("en-US/whats_new/0.49.0.txt", str(caught.exception))
        self.assertEqual(self.fake.writes(), [])

    def test_version_in_review_stops_before_writing(self):
        listing = self.listing("0.49.0")
        synced(self.fake, listing)
        self.fake.get("/v1/apps/app1/appStoreVersions", page(res(
            "appStoreVersions", "v1", platform="MAC_OS", versionString="0.48.0", appVersionState="WAITING_FOR_REVIEW")))
        with self.assertRaises(asc.Failure) as caught:
            self.sync(listing, "0.49.0")
        self.assertIn("WAITING_FOR_REVIEW", str(caught.exception))
        self.assertEqual(self.fake.writes(), [])

    def test_taken_name_is_a_warning(self):
        listing = self.listing("0.48.0")
        synced(self.fake, listing)
        self.fake.get("/v1/appInfos/info1/appInfoLocalizations", page(*[
            res("appInfoLocalizations", f"ail-{locale}", locale=locale, name="Old", subtitle="Old",
                privacyPolicyUrl=f["privacyPolicyUrl"]) for locale, f in listing.locales.items()]))

        def patch(query, payload):
            if "name" in payload["data"]["attributes"]:
                return 409, {"errors": [{"status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
                                         "title": "The provided entity includes an attribute with a value that has already been used",
                                         "detail": "The App Name you entered is already being used."}]}
            return 200, single(res("appInfoLocalizations", "x", **payload["data"]["attributes"]))

        self.fake.on("PATCH", "/v1/appInfoLocalizations/ail-en-US", patch)
        output = self.sync(listing, "0.48.0", contact=CONTACT)
        sent = [c["payload"]["data"]["attributes"] for c in self.fake.calls if c["path"] == "/v1/appInfoLocalizations/ail-en-US"]
        self.assertEqual(sent, [{"name": "Stox – Menu Bar Stocks", "subtitle": "Quotes one click away"},
                                {"subtitle": "Quotes one click away"}])
        self.assertIn("::warning title=App Store Connect", output)
        self.assertIn("already being used", output)
        self.assertIn("名称改不成", output)

    def test_submit_error_is_printed_with_a_hint(self):
        listing = self.listing("0.48.0")
        synced(self.fake, listing)
        self.fake.get("/v1/apps/app1/reviewSubmissions", page(res("reviewSubmissions", "sub1", platform="MAC_OS", state="READY_FOR_REVIEW")))
        self.fake.get("/v1/reviewSubmissions/sub1/items", page(res(
            "reviewSubmissionItems", "item1", rels={"appStoreVersion": {"type": "appStoreVersions", "id": "v1"}}, state="READY_FOR_REVIEW")))
        self.fake.on("PATCH", "/v1/reviewSubmissions/sub1", lambda q, p: (409, {"errors": [{
            "status": "409", "code": "STATE_ERROR.ENTITY_STATE_INVALID", "title": "reviewSubmissions is not in valid state",
            "detail": "This resource cannot be reviewed, please check associated errors to see why.",
            "meta": {"associatedErrors": {"/v1/apps/app1": [{"code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
                                                             "detail": "You must provide privacy details."}]}}}]}))
        output = io.StringIO()
        with self.assertRaises(asc.Failure) as caught, contextlib.redirect_stdout(output):
            api = asc.Api(lambda: "t", send=self.fake.send, sleep=self.sleeps.append)
            asc.Sync(api, listing, "0.48.0", attach_latest=True, submit=True, contact=CONTACT, sleep=self.sleeps.append).run()
        self.assertIn("App 隐私", str(caught.exception))
        self.assertIn("::error title=App Store Connect::PATCH /v1/reviewSubmissions/sub1：409 STATE_ERROR.ENTITY_STATE_INVALID", output.getvalue())
        self.assertIn("You must provide privacy details.", output.getvalue())
        # 版本已经在这个审核提交里了，不再加一次。
        self.assertNotIn(("POST", "/v1/reviewSubmissionItems"), self.fake.writes())

    def test_unresolved_submission_for_this_version_stops(self):
        listing = self.listing("0.48.0")
        synced(self.fake, listing)
        self.fake.get("/v1/apps/app1/reviewSubmissions", page(res("reviewSubmissions", "sub0", platform="MAC_OS", state="UNRESOLVED_ISSUES")))
        self.fake.get("/v1/reviewSubmissions/sub0/items", page(res(
            "reviewSubmissionItems", "item0", rels={"appStoreVersion": {"type": "appStoreVersions", "id": "v1"}}, state="REJECTED")))
        with self.assertRaises(asc.Failure) as caught:
            self.sync(listing, "0.48.0", attach_latest=True, submit=True, contact=CONTACT)
        self.assertIn("UNRESOLVED_ISSUES", str(caught.exception))
        self.assertFalse([w for w in self.fake.writes() if "reviewSubmission" in w[1]])

    def test_dry_run_writes_nothing(self):
        listing = self.listing("0.48.0")
        synced(self.fake, listing)
        self.fake.get("/v1/apps/app1/appStoreVersions", page(res(
            "appStoreVersions", "v0", platform="MAC_OS", versionString="0.47.0", appVersionState="READY_FOR_DISTRIBUTION")))
        self.fake.get("/v1/apps/app1/appInfos", page(res("appInfos", "live", rels={}, state="READY_FOR_DISTRIBUTION")))
        listing.whats_new["en-US"] = ("Bug fixes.", "test")
        output = self.sync(listing, "0.48.0", dry_run=True, attach_latest=True, submit=True)
        self.assertEqual(self.fake.writes(), [])
        self.assertIn("（演练，没有写入）POST /v1/appStoreVersions", output)
        self.assertIn("（演练，没有写入）PATCH /v1/reviewSubmissions/", output)
        self.assertIn("::notice title=App Store Connect::演练", output)


# ---------------------------------------------------------------- 其他


class ListingTests(unittest.TestCase):
    def test_real_listing_passes(self):
        listing = asc.Listing().load()
        self.assertEqual(listing.errors, [])
        self.assertEqual(set(listing.locales), {"en-US", "zh-Hans"})
        self.assertEqual(listing.primary_locale, "en-US")
        self.assertIn("15", listing.locales["zh-Hans"]["description"])  # 港股延时约 15 分钟
        self.assertIn("15 minutes", listing.locales["en-US"]["description"])

    def test_real_listing_with_version(self):
        listing = asc.Listing().load("0.48.0")
        self.assertEqual(listing.errors, [])
        text, source = listing.whats_new["zh-Hans"]
        self.assertTrue(text.startswith("• "))
        self.assertIn("CHANGELOG.md", source)
        self.assertEqual(listing.whats_new["en-US"], (None, None))
        self.assertTrue(any("en-US" in w for w in listing.warnings))

    def test_run_check_on_real_files(self):
        with contextlib.redirect_stdout(io.StringIO()):
            asc.run_check("0.48.0")

    def test_problems_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "listing"
            shutil.copytree(asc.LISTING, root)
            (root / "en-US" / "name.txt").write_text("x" * 31, encoding="utf-8")
            (root / "en-US" / "support_url.txt").write_text("http://whrss.com/support/", encoding="utf-8")
            (root / "zh-Hans" / "keywords.txt").write_text("股票，行情", encoding="utf-8")
            (root / "zh-Hans" / "description.txt").unlink()
            listing = asc.Listing(root).load("1.2.x")
            problems = "\n".join(listing.errors)
            self.assertIn("31 个字", problems)
            self.assertIn("https://", problems)
            self.assertIn("中文逗号", problems)
            self.assertIn("description.txt", problems)
            self.assertIn("版本号 1.2.x", problems)
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(asc.Failure):
                asc.run_check(None, None, root)

    def test_screenshots(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "1.png").write_bytes(png(1440, 900))
            (folder / "2.png").write_bytes(png(2880, 1800, color_type=6))
            (folder / "3.jpg").write_bytes(jpeg(1280, 800))
            (folder / "notes.txt").write_text("不是截图")
            listing = asc.Listing().load(None, folder)
            self.assertEqual(listing.errors, [])
            self.assertEqual([p.name for p in listing.screenshots], ["1.png", "2.png", "3.jpg"])
            self.assertTrue(any("2.png" in w and "透明" in w for w in listing.warnings))
            (folder / "4.png").write_bytes(png(1440, 901))
            self.assertTrue(any("1440×901" in e for e in asc.Listing().load(None, folder).errors))
            for i in range(5, 12):
                (folder / f"{i}.png").write_bytes(png(1440, 900))
            self.assertTrue(any("最多 10 张" in e for e in asc.Listing().load(None, folder).errors))
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(any("没有 PNG" in e for e in asc.Listing().load(None, tmp).errors))

    def test_image_info(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "image"
            cases = [
                (png(1440, 900), ("PNG", 1440, 900, False)),
                (png(2560, 1600, color_type=6), ("PNG", 2560, 1600, True)),
                (png(1280, 800, color_type=4), ("PNG", 1280, 800, True)),
                (png(1280, 800, trns=True), ("PNG", 1280, 800, True)),
                (jpeg(2880, 1800), ("JPEG", 2880, 1800, False)),
                (b"GIF89a....", None),
                (b"\xff\xd8\x00\x00", None),
            ]
            for data, expected in cases:
                path.write_bytes(data)
                self.assertEqual(asc.image_info(path), expected)

    def test_changelog_whats_new(self):
        text = "\n".join([
            "# 更新日志", "", "## 0.49.0", "",
            "- 新的 `stox-cli flow`，见 [文档](https://example.com/a)。",
            "  - 第二层", "", "", "", "### 小节", "- 隐藏金额换成 ****", "",
            "## 0.48.0", "", "- 旧的", "## 0.4", "- 不该匹配",
        ])
        section = asc.changelog_section(text, "0.49.0")
        self.assertNotIn("旧的", section)
        self.assertEqual(asc.plain_text(section), "• 新的 stox-cli flow，见 文档。\n  • 第二层\n\n小节\n• 隐藏金额换成 ****")
        self.assertEqual(asc.changelog_section(text, "0.4"), "- 不该匹配")
        self.assertEqual(asc.changelog_section(text, "0.47.0"), "")
        long = asc.plain_text("- " + "很长" * 3000)
        self.assertEqual(len(long), 4000)
        self.assertTrue(long.endswith("…"))

    def test_age_rating_answers_only_send_returned_keys(self):
        current = {"violenceRealistic": None, "gambling": True, "lootBox": False, "contests": "NONE",
                   "kidsAgeBand": None, "ageRatingOverrideV2": "NINE_PLUS"}
        self.assertEqual(asc.age_rating_answers(current), {"violenceRealistic": "NONE", "gambling": False})

    def test_contact(self):
        self.assertEqual(asc.parse_contact("Wei\nHu\n+86 138 0000 0000\na@example.com\n"), CONTACT)
        with self.assertRaises(asc.Failure):
            asc.parse_contact("Wei Hu\na@example.com")


class JwtTests(unittest.TestCase):
    def test_der_to_raw(self):
        def der(r, s):
            body = b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
            return b"\x30" + bytes([len(body)]) + body

        r = b"\x80" + b"\x01" * 31  # 最高位是 1：DER 里前面补了 0x00
        s = b"\x02" * 30  # 前面的两个字节是 0：DER 里只有 30 个字节
        raw = asc.der_to_raw(der(b"\x00" + r, s))
        self.assertEqual(raw, r + b"\x00\x00" + s)
        self.assertEqual(len(raw), 64)
        # 长度用长格式写（0x81）也认。
        body = b"\x02\x01\x05\x02\x01\x07"
        self.assertEqual(asc.der_to_raw(b"\x30\x81" + bytes([len(body)]) + body + b"\x00\x00"),
                         b"\x00" * 31 + b"\x05" + b"\x00" * 31 + b"\x07")
        with self.assertRaises(ValueError):
            asc.der_to_raw(b"\x31\x06\x02\x01\x05\x02\x01\x07")
        with self.assertRaises(ValueError):
            asc.der_to_raw(der(b"\x01" * 33, b"\x01"))

    @unittest.skipUnless(HAS_OPENSSL, "没有 openssl")
    def test_jwt_signature_verifies(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", tmp / "ec.pem"], check=True)
            subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", tmp / "ec.pem", "-out", tmp / "AuthKey.p8"], check=True)
            subprocess.run(["openssl", "ec", "-in", tmp / "ec.pem", "-pubout", "-out", tmp / "pub.pem"], check=True, capture_output=True)
            for _ in range(5):  # 签名是随机的，多签几次，碰到 r、s 前面有 0 的情况
                token = asc.make_jwt("KEY123", "issuer-uuid", tmp / "AuthKey.p8", now=1_700_000_000)
                header, payload, signature = token.split(".")
                decode = lambda part: base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
                self.assertEqual(json.loads(decode(header)), {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
                claims = json.loads(decode(payload))
                self.assertEqual(claims["iss"], "issuer-uuid")
                self.assertEqual(claims["aud"], "appstoreconnect-v1")
                self.assertEqual(claims["iat"], 1_700_000_000)
                self.assertLessEqual(claims["exp"] - claims["iat"], 20 * 60)
                raw = decode(signature)
                self.assertEqual(len(raw), 64)

                def integer(value):
                    value = value.lstrip(b"\x00") or b"\x00"
                    if value[0] & 0x80:
                        value = b"\x00" + value
                    return b"\x02" + bytes([len(value)]) + value

                body = integer(raw[:32]) + integer(raw[32:])
                (tmp / "sig.der").write_bytes(b"\x30" + bytes([len(body)]) + body)
                result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", tmp / "pub.pem", "-signature", tmp / "sig.der"],
                                        input=f"{header}.{payload}".encode(), capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(HAS_OPENSSL, "没有 openssl")
    def test_token_is_renewed(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey.p8"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", key],
                           check=True, capture_output=True)
            now = [1_700_000_000]
            tokens = asc.TokenSource("K", "I", key, clock=lambda: now[0])
            first = tokens()
            now[0] += 10 * 60
            self.assertEqual(tokens(), first)
            now[0] += 6 * 60
            self.assertNotEqual(tokens(), first)

    def test_load_key(self):
        pem = "-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----"
        with tempfile.TemporaryDirectory() as tmp:
            key_id, issuer, path = asc.load_key({"ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_KEY_P8": pem}, tmp)
            self.assertEqual((key_id, issuer), ("K", "I"))
            self.assertEqual(path.read_text(), pem + "\n")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with tempfile.TemporaryDirectory() as tmp:
            encoded = base64.b64encode(pem.encode()).decode()
            _, _, path = asc.load_key({"ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_KEY_P8": encoded[:20] + "\n" + encoded[20:]}, tmp)
            self.assertEqual(path.read_text(), pem + "\n")
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(asc.Failure):
                asc.load_key({"ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_KEY_P8": "bm90IGEga2V5"}, tmp)
            with self.assertRaises(asc.Failure) as caught:
                asc.load_key({"ASC_KEY_P8": pem}, tmp)
            self.assertIn("ASC_KEY_ID、ASC_ISSUER_ID", str(caught.exception))


class ApiTests(unittest.TestCase):
    def test_retries_rate_limit_and_reports_errors(self):
        fake = FakeApple()
        sleeps = []
        fake.get("/v1/apps", (429, {"errors": []}), page(res("apps", "a")))
        api = asc.Api(lambda: "t", send=fake.send, sleep=sleeps.append)
        self.assertEqual(api.get_all("/v1/apps")[0][0]["id"], "a")
        self.assertEqual(sleeps, [2])
        fake.on("PATCH", "/v1/apps/a", lambda q, p: (409, {"errors": [{"status": "409", "code": "ENTITY_ERROR", "title": "Bad", "detail": "No"}]}))
        with self.assertRaises(asc.ApiError) as caught, contextlib.redirect_stdout(io.StringIO()):
            api.write("PATCH", "/v1/apps/a", {"data": {"type": "apps", "id": "a", "attributes": {}}})
        self.assertEqual(caught.exception.lines(), ["409 ENTITY_ERROR：Bad — No"])

    def test_next_page_must_stay_on_the_api_host(self):
        fake = FakeApple()
        fake.get("/v1/apps", page(res("apps", "a"), next_url="https://evil.example/v1/apps?cursor=2"))
        api = asc.Api(lambda: "t", send=fake.send)
        with self.assertRaises(asc.Failure):
            api.get_all("/v1/apps")


if __name__ == "__main__":
    unittest.main()
