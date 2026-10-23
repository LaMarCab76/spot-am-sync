#!/usr/bin/env python3
"""Inspect an exported Music library without printing names, IDs, paths or playback history."""
import argparse
import json
import plistlib
from collections import Counter
from pathlib import Path


def summarize(path: Path) -> dict:
    with path.open("rb") as stream:
        data = plistlib.load(stream)
    tracks = data.get("Tracks")
    playlists = data.get("Playlists")
    if not isinstance(tracks, dict) or not isinstance(playlists, list):
        raise ValueError("El archivo no contiene las colecciones Tracks y Playlists esperadas.")
    values = list(tracks.values())
    if not all(isinstance(item, dict) for item in values + playlists):
        raise ValueError("El inventario contiene elementos con estructura desconocida.")
    sequences = [playlist.get("Playlist Items", []) for playlist in playlists]
    if not all(isinstance(items, list) and all(isinstance(item, dict) for item in items) for items in sequences):
        raise ValueError("Una playlist contiene referencias con estructura desconocida.")
    references = [item.get("Track ID") for items in sequences for item in items]
    identifiers = {track.get("Track ID") for track in values if track.get("Track ID") is not None}
    kinds = Counter(track.get("Track Type", "unknown") for track in values)
    return {
        "exportParsed": True,
        "tracks": len(values),
        "playlistsIncludingSystemAndFolders": len(playlists),
        "playlistOccurrencesIncludingSystem": len(references),
        "missingTrackReferences": sum(identifier not in identifiers for identifier in references),
        "hasLibraryPersistentID": bool(data.get("Library Persistent ID")),
        "tracksWithPersistentID": sum(bool(track.get("Persistent ID")) for track in values),
        "entriesWithPlaylistPersistentID": sum(bool(playlist.get("Playlist Persistent ID")) for playlist in playlists),
        "remoteTracks": kinds.get("Remote", 0),
        "fileTracks": kinds.get("File", 0),
        "otherTrackTypes": sum(count for kind, count in kinds.items() if kind not in {"Remote", "File"}),
        "appleMusicFlagCount": sum(bool(track.get("Apple Music")) for track in values),
        "playlistOnlyTracks": sum(bool(track.get("Playlist Only")) for track in values),
        "folders": sum(bool(playlist.get("Folder")) for playlist in playlists),
        "smartPlaylists": sum("Smart Info" in playlist or "Smart Criteria" in playlist for playlist in playlists),
        "systemOrMasterPlaylists": sum(bool(playlist.get("Master") or playlist.get("Distinguished Kind")) for playlist in playlists),
        "playlistsWithRepeatedTrackIDs": sum(len(items) != len({item.get("Track ID") for item in items}) for items in sequences),
        "observedISRCFields": any("ISRC" in track for track in values),
        "observedCatalogIDFields": any(any(key in track for key in ["Catalog ID", "Store ID", "Store Track ID"]) for track in values),
        "cloudCompletenessVerified": False,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml", type=Path, help="Archivo XML exportado desde Música")
    arguments = parser.parse_args()
    try:
        print(json.dumps(summarize(arguments.xml), indent=2))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"No se pudo validar el XML ({type(error).__name__}). No se considera un inventario vacío.\n")
