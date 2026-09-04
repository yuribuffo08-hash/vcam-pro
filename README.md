# Virtual Camera Pro (iOS 15 - 17 Rootless)

Un tweak avanzato, open-source e stabile per sostituire l'output della fotocamera su iOS a livello di sistema operativo (`mediaserverd`). 
Testato e ottimizzato per **Dopamine 3 (Rootless)** su dispositivi **arm64 / arm64e** (incluso iPhone XR / A12 Bionic su iOS 17.6.1).

---

## Caratteristiche Principali

* **Integrazione Nativa nelle Impostazioni**:
  * Pannello dedicato in *Impostazioni -> Virtual Camera Pro*.
  * Switch On/Off rapido.
  * Selettore di modalità (*Foto* o *Video*).
  * Opzione *Loop continuo* per i video.
* **Selettore da Rullino Fotografico (Camera Roll)**:
  * Pulsante *"Seleziona dalla Galleria 📁"* per scegliere direttamente qualsiasi foto o video memorizzato sull'iPhone, senza bisogno di Filza o percorsi manuali.
* **Motore ad Alte Prestazioni senza Memory Leak**:
  * Risolto il problema storico dei crash di `mediaserverd`: i frame video vengono riprodotti in **streaming on-demand** tramite `AVAssetReader` (RAM footprint < 10 MB invece di 2 GB di buffer non compressi).
  * Gestione esplicita della memoria con `@autoreleasepool` su ogni frame elaborato.
  * Ridimensionamento proporzionale hardware (*Aspect Fill*) per evitare distorsioni o bande nere.
* **Sincronizzazione Dinamica via Darwin IPC**:
  * Il menu Impostazioni e `mediaserverd` comunicano in tempo reale tramite notifiche Darwin (`com.vcam.pro/preferencesChanged`). Ogni modifica viene applicata all'istante senza dover riavviare `mediaserverd`.

---

## Come Compilare il Pacchetto (.deb)

Grazie al workflow GitHub Actions incluso in `.github/workflows/build.yml`, non è necessario installare Theos o macOS sul proprio computer:

1. Crea un repository personale su GitHub (es. `vcam-pro`).
2. Collega questa cartella locale e fai il push:
   ```bash
   git remote set-url origin https://github.com/<tuo-utente>/<tuo-repo>.git
   git push -u origin main --force
   ```
3. Vai nella scheda **Actions** del tuo repository GitHub: il workflow `Build VCamPro` compilerà automaticamente il tweak.
4. Scarica il file `VCamPro-DEB.zip` dalla sezione **Artifacts** ed estrai il file `.deb`.

---

## Installazione su iPhone

1. Trasferisci il file `.deb` sull'iPhone (tramite AirDrop, SSH o scaricandolo da Safari).
2. Apri il file con **Sileo** o **Filza** e premi **Installa**.
3. Riavvia la userspace (o fai Respring).
4. Vai in **Impostazioni -> Virtual Camera Pro**, abilita il tweak e seleziona un video o una foto dalla Galleria.
