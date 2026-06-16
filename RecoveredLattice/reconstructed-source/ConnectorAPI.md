# Reconstructed Local Connector API

Source evidence:

- `safari-extension/reformatted/background.js`
- `main-app/Lattice.strings.txt`
- `original-metadata/recovered-api-paths.txt`

## Base URL

The Safari extension defaults to:

```text
http://127.0.0.1:29467
```

The main prefix is:

```text
/connector
```

The app strings also mention `/api/v1/collections` and `/api/v1/metadata`.

## Endpoints

### GET `/connector/status`

Expected response fields inferred from the extension:

```json
{
  "ok": true,
  "apiVersion": "...",
  "serverVersion": "...",
  "appVersion": "...",
  "version": "...",
  "readOnly": false,
  "capabilities": ["pdf-upload"],
  "baseURL": "http://127.0.0.1:29467",
  "browserExtensionEnabled": true
}
```

The extension accepts `serverVersion`, `appVersion`, or `version` as the server version.

### GET `/connector/collections`

The extension accepts either a raw array or an object with `collections`.

Inferred collection fields:

```json
{
  "id": "...",
  "name": "...",
  "path": "...",
  "depth": 0
}
```

### GET `/connector/tags`

The extension accepts either a raw array or an object with `tags`.

Inferred tag fields:

```json
{
  "id": "...",
  "name": "...",
  "colorHex": "#..."
}
```

### GET `/connector/metadata`

The extension sends query parameters only when values are non-empty strings.

Likely accepted identifiers:

- `doi`
- `arxivId`
- `isbn`
- `title`

The main app string says: `Provide at least one of doi, arxivId, isbn, or title.`

### POST `/connector/papers`

Inferred request body:

```json
{
  "title": "...",
  "authors": "A; B; C",
  "year": 2026,
  "journal": "...",
  "abstract": "...",
  "doi": "...",
  "volume": "...",
  "issue": "...",
  "pages": "...",
  "isbn": "...",
  "paperType": "...",
  "collections": ["Collection/Path"],
  "tags": ["tag"],
  "enrich": true,
  "strategy": "replace"
}
```

`strategy` is `replace` only when the user chooses replacement after a duplicate conflict; otherwise it is null or absent.

Inferred response body:

```json
{
  "id": "...",
  "title": "...",
  "authors": "...",
  "year": 2026,
  "doi": "...",
  "pdfAttached": false,
  "enrichmentStatus": "none",
  "warnings": [],
  "alreadyExists": false,
  "conflict": null
}
```

### PUT `/connector/papers/{id}/pdf`

Content type must be:

```text
application/pdf
```

The extension uses:

```text
/connector/papers/{id}/pdf?force=true
```

when replacing an existing duplicate.

## Error behavior

The extension maps these HTTP statuses:

- `409`: duplicate paper. Response may include `existingPaperID`, `existingTitle`, `conflictField`, `latticeURL`.
- `413`: PDF exceeds the 200 MB upload limit.
- `422`: free-tier library limit.
- `503`: PDF upload destination not configured.

Strings in the main app also mention:

- `Origin not allowed`
- `Method Not Allowed`
- `Content-Type must be application/pdf`
- `Invalid PDF payload`
- `PDF already attached`
- `Browser extension integration is disabled`

## CORS/origin notes

Recovered strings mention:

- `chrome-extension`
- `safari-web-extension`
- `citationBridgeAllowedOrigins`
- `Access-Control-Allow-Origin`
- `Access-Control-Allow-Methods`
- `GET, POST, PUT, OPTIONS`

The server appears to accept loopback clients and explicit browser extension origins.
