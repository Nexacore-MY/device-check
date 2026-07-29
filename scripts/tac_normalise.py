"""Normalise MoazEb/tac-database tac_full.csv -> tac_catalogue.csv (tac,brand,model).

  python3 gen_tac.py tac_full.csv > tac_catalogue.csv

Rules:
  * TAC is zero-padded back to 8 digits (6,621 source rows lost leading zeros to a
    numeric round-trip; padding produces zero collisions with existing 8-digit TACs).
  * SPECS field-1 only. It is the field that agrees with the Apple A-number; field-2 is
    stale in 17% of Apple rows. When field-1 is just the brand repeated, model is NULL.
  * All 200 GSMA test-IMEI rows are dropped (broad 'TEST IMEI' match, not the exact
    phrase -- 23 rows use different wording, e.g. 'FORD IT IS A TEST IMEI USED').
  * The TAC='0' junk row is dropped ('000000000000000' passes Luhn, so it would
    otherwise be a live catalogue hit).
  * A TAC whose source rows disagree on EITHER brand OR model is dropped entirely.
    Brand disagreement matters: TAC 86231305 is filed under both VIVO and REALME with
    model text 'VIVO V13 5G' but a realme model code (RMX3041). Keeping either row
    would enrol a realme as a vivo.
"""
import csv, collections, re, sys

KEEP_UPPER = {'TCL','LG','ZTE','HTC','BLU','HMD','NEC','RIM','UMX','SFR','BQ','LTE','NFC','TV','HD',
              'XL','XS','XR','SE','GT','CE','5G','4G','3G','2G','JBL','ASUS','ROG','II','III','IV','DS','NA'}
SPECIAL = {'IPHONE':'iPhone','IPAD':'iPad','IPOD':'iPod','IMAC':'iMac','IWATCH':'iWatch','IQOO':'iQOO',
           'ONEPLUS':'OnePlus','REALME':'realme','VIVO':'vivo','OPPO':'OPPO','ZTE':'ZTE','TCL':'TCL',
           'LG':'LG','HTC':'HTC','HMD':'HMD','POCO':'POCO','REDMI':'Redmi','XIAOMI':'Xiaomi',
           'HONOR':'HONOR','ITEL':'itel','TECNO':'TECNO','INFINIX':'Infinix','SAMSUNG':'Samsung',
           'APPLE':'Apple','HUAWEI':'HUAWEI','NOKIA':'Nokia','MOTOROLA':'Motorola','SONY':'Sony',
           'GOOGLE':'Google','BENQ':'BenQ','ULEFONE':'Ulefone','MEIZU':'Meizu','LENOVO':'Lenovo'}
# Apple's lower-case suffix models: '16E' is marketed as '16e'.
LOWER_SUFFIX = re.compile(r'^(\d{1,2})E$')


def case_token(t):
    u = t.upper()
    if u in SPECIAL: return SPECIAL[u]
    if u in KEEP_UPPER: return u
    if LOWER_SUFFIX.match(u): return u.lower()
    if any(c.isdigit() for c in u):
        m = re.match(r'^([A-Z]+)(\d+)$', u)            # FLIP6 / NOTE13 / SPARK7
        if m and len(m.group(1)) >= 3: return m.group(1).capitalize() + m.group(2)
        return u                                        # A54 / SM-S928B / RMX5072 / 2502FRA65G
    return u.capitalize()


def pretty(s): return ' '.join(case_token(t) for t in s.split())


rows = list(csv.DictReader(open(sys.argv[1] if len(sys.argv) > 1 else 'tac_full.csv')))
out = {}
conflict = set()
skipped = collections.Counter()

for r in rows:
    tac_raw = (r['TAC'] or '').strip()
    if not tac_raw.isdigit():
        skipped['non_digit'] += 1; continue
    tac = tac_raw.zfill(8)
    if len(tac) != 8:
        skipped['too_long'] += 1; continue
    if tac == '00000000':
        skipped['zero_tac'] += 1; continue
    specs = (r['SPECS'] or '').strip()
    if 'TEST IMEI' in specs.upper():
        skipped['test_imei'] += 1; continue
    brand_raw = (r['Brand'] or '').strip()
    if not brand_raw:
        skipped['no_brand'] += 1; continue
    f1 = specs.split(',')[0].strip()
    if f1.upper() in ('', 'N/A'): f1 = ''
    model = '' if (f1 == '' or f1.upper() == brand_raw.upper()) else f1
    key = (brand_raw.upper(), model.upper())
    if tac in out:
        if out[tac][2] != key: conflict.add(tac)
        continue
    out[tac] = (pretty(brand_raw), pretty(model) if model else '', key)

for t in conflict:
    out.pop(t, None)

w = csv.writer(sys.stdout, lineterminator='\n')
w.writerow(['tac', 'brand', 'model'])
for t in sorted(out):
    w.writerow([t, out[t][0], out[t][1]])

print("kept %d | skipped %s | conflicts dropped %d | with model %d | brand-only %d"
      % (len(out), dict(skipped), len(conflict),
         sum(1 for v in out.values() if v[1]), sum(1 for v in out.values() if not v[1])),
      file=sys.stderr)
