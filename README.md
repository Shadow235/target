# Scope Target – detekce zásahů přes dalekohled (iPad Pro)

Aplikace pro iPad (iPadOS 17+). Snímá vzdálený papírový terč kamerou na dalekohledu, sama najde nové průstřely a ohlásí je: číslo rány, body a směr od středu, hlasem česky. Inspirací je LongShot Hawk, jen s vlastní kamerou a bez placeného hardwaru.

## Funkce

- **Zdroje obrazu**
  - vestavěná kamera iPadu přes digiscoping adaptér na okulár,
  - USB-C kamera (UVC) na dalekohledu,
  - WiFi kamera: MJPEG stream nebo opakované stahování JPEG snímku (ESP32-CAM, IP kamery, aplikace „IP Webcam“ na starém telefonu).
- **Vyznačení terče čtyřmi rohy.** Aplikace terč perspektivně narovná a spočítá měřítko v px/mm.
- **Automatická detekce zásahů**
  - kompenzuje chvění obrazu,
  - průměruje snímky proti tetelení vzduchu,
  - vyrovnává jas,
  - novou díru potvrdí až po několika snímcích,
  - při náhlé změně světla (mrak) nebo pohybu kamery sama založí novou referenci.
- **Bodování** kruhových terčů (předvolby ISSF i vlastní rozměry, vnitřní desítka X, dotyk čáry = vyšší hodnota). Terč bez kruhů jde použít i bez bodování.
- **Statistika skupiny**
  - největší rozptyl (ES) a střední poloměr v mm, MOA i mrad,
  - střed skupiny,
  - **korekce zaměřovače**.
- **Ruční úpravy:** přidání přehlédnuté rány, přesunutí, smazání, posunutí středu kruhů.
- **Historie relací** (JSON v aplikaci Soubory) a export CSV.

## Postup na střelnici

1. **Zdroj:** vyberte kameru nebo zadejte URL WiFi kamery.
2. **Kamera:** zaostřete dalekohled a přetáhněte 4 zelené rohy na okraje terče. Pořadí je vlevo nahoře → vpravo nahoře → vpravo dole → vlevo dole.
3. **Nastavení:**
   - předvolba terče a skutečné rozměry vyznačené plochy,
   - ráže,
   - vzdálenost.
4. **Potvrdit terč.** Expozice kamery se zamkne, aby automatika neměnila jas.
5. V režimu **Terč** zkontrolujte, že modré kruhy sedí na natištěných. Pokud ne, nástrojem **Střed terče** klepněte do středu.
6. **Spustit detekci.** Aplikace si nasnímá čistý terč jako referenci. Pak střílejte.
7. Po přelepení nebo výměně terče stiskněte **Nový terč**.

### Tipy pro spolehlivou detekci

- Průstřel by měl mít v obraze **aspoň 3–4 px**. Aktuální hodnotu ukazuje Nastavení → Detekce. Pomůže větší zoom dalekohledu, nebo vyznačit jen menší oblast kolem středu (a zadat její rozměry).
- Stabilní stativ je důležitější než rozlišení kamery.
- Při silném tetelení vzduchu snižte citlivost nebo zvyšte počet potvrzovacích snímků.
- Pro ladění zapněte **Zobrazit rozdílový obraz**. Červeně uvidíte, co detektor považuje za změnu.
- Díru v už existující díře detekce nerozliší. Takovou ránu přidejte ručně nástrojem **Přidat ránu**.

## Struktura

```
Packages/HitCore/     čistý Swift (bez iOS frameworků), testovatelný i na Linuxu
  GrayImage.swift       obraz, rozmazání, posun, průměrování snímků
  Registration.swift    odhad posunu (stabilizace)
  BlobDetector.swift    hledání souvislých změn (hysterezní práh)
  HitDetector.swift     stavový detektor nových průstřelů
  Scoring.swift         terče, bodování, statistika, MOA/mrad, hlasový popis
  TargetFrame.swift     převod pixely ↔ milimetry
ScopeTarget/          iPad aplikace (SwiftUI)
  Camera/               AVFoundation (vestavěná + USB-C), MJPEG, JPEG snímek
  Processing/           rektifikace terče (Core Image) → HitCore
  Model/                stav aplikace, relace, ukládání
  Views/                UI
project.yml           definice Xcode projektu (XcodeGen)
```

## Webová verze (PWA) – instalace přes prohlížeč

Složka `web/` obsahuje stejnou aplikaci jako webovou aplikaci. Nepotřebuje Mac, Xcode ani podpis. Instaluje se z prohlížeče a funguje i offline.

1. Nahrajte repozitář na GitHub a v *Settings → Pages* zvolte *Source: GitHub Actions*. Workflow `.github/workflows/pages.yml` spustí testy a web zveřejní na `https://<uživatel>.github.io/<repozitář>/`.
2. **iPad / iPhone:** otevřete adresu v Safari → *Sdílet* → *Přidat na plochu*.
   **Android / Chrome / Edge:** tlačítko *Nainstalovat* v aplikaci nebo v adresním řádku.
3. Pro vyzkoušení bez kamery zvolte zdroj **Ukázkový terč (simulace)**.

Lokální spuštění: `cd web` a pak `python -m http.server 8080`. Kamera v prohlížeči funguje jen přes HTTPS nebo na `localhost`.

Testy jádra (Node 20+): `cd web` a pak `npm test`.

### Rozdíly proti iPad aplikaci

- **WiFi kamera (MJPEG / snímek)** jde v prohlížeči analyzovat, jen když posílá hlavičku CORS (`Access-Control-Allow-Origin`). Z HTTPS stránky navíc prohlížeč nenačte `http://` adresu. Běžné levné kamery (ESP32-CAM apod.) tyto podmínky bez úprav nesplňují. Pro WiFi kameru je proto vhodnější nativní aplikace, nebo malý převaděč (proxy) s HTTPS a CORS.
- **Zamknutí expozice a zoom** jsou dostupné jen tam, kde je prohlížeč podporuje (typicky Chrome na Androidu). Safari na iPadu zamknutí expozice zatím neumí.
- **Relace** se ukládají v úložišti prohlížeče. Zálohu a obnovu najdete v *Nastavení → Data*.
- Snímky se před průměrováním zarovnávají na referenci. iPad verze to zatím nedělá a při chvění obrazu hlásí falešné zásahy na hranách kruhů.

## Sestavení bez Macu (z Windows)

Aplikace pro iOS se dá sestavit jen na macOS. Bez vlastního Macu to jde takto:

1. Nahrajte složku do (klidně soukromého) repozitáře na GitHubu. Workflow `.github/workflows/build.yml` se spustí automaticky na macOS runneru:
   - spustí testy jádra,
   - vygeneruje projekt,
   - sestaví nepodepsané `ScopeTarget-unsigned.ipa` jako artifact.
2. IPA stáhněte z GitHub Actions → běh → *Artifacts*.
3. Na Windows ho nainstalujte do iPadu přes **[Sideloadly](https://sideloadly.io)**. Připojte iPad kabelem, přihlaste se Apple ID a Sideloadly aplikaci podepíše. Na iPadu pak zapněte *Nastavení → Soukromí a zabezpečení → Režim vývojáře*.
   - S bezplatným Apple ID platí podpis **7 dní**, pak je potřeba instalaci zopakovat.
   - S placeným Apple Developer účtem (99 USD/rok) platí rok a jde použít i TestFlight.

### S Macem

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open ScopeTarget.xcodeproj
```

Pak v Xcode vyberte svůj tým (Signing & Capabilities) a spusťte aplikaci na iPadu.

### Testy jádra (i na Windows přes Docker)

```bash
docker run --rm -v "$PWD/Packages/HitCore:/pkg" -w /pkg swift:6.0 swift test
```

## Omezení a další kroky

- RTSP stream zatím není podporovaný. Šel by přidat přes MobileVLCKit, nebo jen dekodér H.264 přes VideoToolbox.
- Terče se zatím nerozpoznávají automaticky, rohy se vyznačují ručně. Další krok: automatické nalezení středu a kruhů.
- Zatím chybí dálkové hlášení na jiné zařízení, např. do telefonu u střelce.
