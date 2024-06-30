# DATAFETCH: Advanced Data Retrieval

Questo script bash raccoglie informazioni dettagliate sul sistema operativo e sull'hardware di un computer GNU/Linux.

## Dipendenze
- bash
- lscpu, lspci, free, awk, grep (comandi standard di Linux)

## Utilizzo
1. Assicurarsi che lo script abbia i permessi di esecuzione:

chmod +x datafetch.sh

2. Eseguire lo script:

./datafetch.sh

## Funzionalità
- Ottiene informazioni sulla CPU, RAM, GPU, swap, bootloader, init system, filesystem, etc.
- Identifica il sistema operativo, il **livello utente di utilizzo**, l'architettura, il kernel, l'ambiente desktop (DE), etc.
- Rileva il gestore dei pacchetti e l'helper AUR utilizzato (solo in caso di Arch & Arch-based).
- Informazioni sui server grafici e audio in uso.

## Autore
Klod Cripta

## Licenza
Questo progetto è sotto licenza MIT - vedere il file LICENSE.md per ulteriori dettagli.
