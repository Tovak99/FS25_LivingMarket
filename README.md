# FS25 Living Market (Lebendiger Markt)

Script-Mod für den **Landwirtschafts-Simulator 25**. Verkaufsstellen nehmen nicht mehr unbegrenzt an: Jede Station hat pro Ware einen **Bedarf**, der beim Verkauf sinkt und sich mit der Zeit langsam wieder auffüllt. Ziel ist ein lebendiger Markt mit Nachfrage, Engpässen, Preisänderungen und Angeboten.

> Status: Entwicklungsversion 0.2.1.60 (Singleplayer getestet, Multiplayer noch ungetestet), noch nicht veröffentlicht.

## Funktionen

- **Begrenzter Bedarf** pro Verkaufsstelle und Ware nach Warengruppen, z. B. Getreide 250.000 l (40 % Auffüllung je Monat), Lebensmittel 30.000 l (30 %), hochwertige Endprodukte 10.000 l (20 %)
  - einstellbar in `modSettings/FS25_LivingMarket_config.xml` (wird beim ersten Start aus `config/defaultConfig.xml` angelegt)
- **Preis folgt dem Bedarf:** ab 50 % freiem Bedarf Normalpreis, darunter immer stärker fallend bis −50 % (bei 10 % und weniger)
- **Marktereignisse** (etwa 10–20 gleichzeitig, verteilt über den Monat, je 1–2 Monate, mit Meldung; eigene Ansicht „Marktnachrichten“ mit Filter Alle/Lieferbar):
  - Engpass an einer Station: mehr Bedarf, Preis +10–25 %
  - Überangebot an einer Station: weniger Bedarf, Preis −10–25 %
  - marktweit gefragt oder Flaute für eine Ware (einen Monat vorher angekündigt)
  - dazu kleine Schwankungen des Bedarfs (±10 %) zu jedem Monat
- **Ausgenommen:** eigene Produktionen (Produktionen der Karte, z. B. die BGA, zählen als Verkaufsstelle), Geld/Bargeld (Bank) und Lieferungen für laufende Aufträge
- **Eigene Seite im Ingame-Menü (ESC)**
  - eine Zeile pro Ware: Lager, beste Station (höchster Preis *mit freiem Bedarf*), Preis je 1000 l, verkaufbare Menge, Erlös
  - Detailfenster mit allen Stationen der gewählten Ware: Preis, Frei / Maximum
  - Filter per Klick: Alle Waren · Lagernd · Favoriten; Suche nach Ware oder Station
  - Favoriten (Stern-Spalte), gemeinsam für alle Spieler im Spielstand gespeichert
  - Ansicht **Verkäufe**: die letzten 50 Verkäufe des eigenen Hofs (Zeit, Ware, Station, Menge, Preis, Erlös, Marktlage, Ereignis), auch Paletten und Ballen; Auftragsware zählt nicht
  - Ansicht **Verträge**: Stationen schreiben Lieferungen aus (Menge, Frist, Festpreis bis +10 %, Bonus); annehmen per Taste mit Rückfrage; Lieferung zum Festpreis ohne Marktlage; bei Nichterfüllung oder Kündigung 50 % Strafe auf die fehlende Menge
  - **Ansehen** je Hof und Station (1–5 Sterne) im Detailfenster und bei den Verträgen; steigt mit erfüllten, sinkt mit gescheiterten Verträgen und pendelt langsam zur Mitte zurück
  - **Optionen** (Regler-Symbol oben rechts): Anzahl der Verträge – so viele Ausschreibungen gibt es gleichzeitig (Standard 6, höchstens 15), fehlende werden innerhalb eines Spieltags ersetzt; gilt für das ganze Spiel, im Mehrspieler nur Host/Admin
  - Waren ohne Verkaufsstelle (z. B. Wartung, Strom, Wasser, Gärreste) bekommen keine Ereignisse und keine Verträge
- **Schimpfwortfilter des Spiels abgeschaltet** (sonst wird z. B. „Aldi“ zu „Al$i“) – Idee aus „Disable Profanity Filter“ von Supermaschine
- **Mehrsprachig:** Deutsch, Englisch, Französisch, Polnisch, Niederländisch, Spanisch, Italienisch
- **Speichert den Bedarf im Spielstand** (`livingMarket.xml` im Savegame-Ordner)
- **Multiplayer-fähig aufgebaut:** Der Server verwaltet den Bedarf und synchronisiert ihn (noch ungetestet)

## Installation

1. Den Inhalt dieses Repositorys als Zip packen, sodass `modDesc.xml` direkt im Zip liegt (nicht in einem Unterordner).
2. Die Zip **`FS25_LivingMarket.zip`** nennen und in den Mods-Ordner legen:
   `Dokumente/My Games/FarmingSimulator2025/mods/`
3. Beim Laden des Spielstands die Mod in der Mod-Auswahl aktivieren.

## Aufbau

| Datei | Inhalt |
|---|---|
| `modDesc.xml` | Mod-Beschreibung, Version, Skripte, Sprachen |
| `scripts/LivingMarket.lua` | Kernlogik: Bedarf, Hooks auf `SellingStation`, Lager, Preise, Menüseite einhängen |
| `scripts/LivingMarketEvents.lua` | Marktereignisse und Schwankungen |
| `scripts/gui/LivingMarketFrame.lua` | Menüseite: Warenliste, Detailfenster, Suche, Filter |
| `scripts/events/LivingMarketSyncEvent.lua` | Multiplayer-Sync Server → Clients |
| `gui/LivingMarketFrame.xml` | Layout und Profile der Menüseite |
| `config/defaultConfig.xml` | Einstellungen: Warengruppen, Maximum und Auffüllung je Monat, Marktlage, Schwankungen, Marktereignisse |
| `languages/l10n_*.xml` | Texte in allen Sprachen |

## Fehlersuche

Die Mod schreibt Zeilen mit dem Präfix `[LivingMarket]` in die `log.txt` (`Dokumente/My Games/FarmingSimulator2025/`), u. a. alle Stationen mit ihren Waren beim ersten Öffnen der Seite.
