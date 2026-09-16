# Smart Route Finder for Daily Commuters

Smart Route Finder for Daily Commuters is a SWI-Prolog web application for planning everyday journeys between real locations. It provides a browser interface for location search, route preferences, walking and vehicle estimates, map display, live navigation, and alternative-route selection.

The application uses free OpenStreetMap services:

- **Nominatim** for place search and reverse geocoding.
- **OSRM** for live road routing and route geometry.
- A small Prolog graph as an offline/demo fallback.

The frontend is served by the Prolog HTTP server and uses Leaflet with OpenStreetMap tiles.

## Features

- Current browser location detection.
- Start-location and destination autocomplete.
- Real place search through Nominatim.
- Fastest and shortest route preferences.
- Walking and vehicle travel modes.
- Walking-time estimates based on an average speed of 5 km/h.
- Vehicle-time estimates returned by the routing service.
- Interactive OpenStreetMap map.
- Distinct source and destination markers.
- Live navigation using browser geolocation.
- Remaining-distance updates while travelling.
- Arrival detection near the destination.
- Stop-navigation cleanup and road-status reset.
- Online/offline connection status.
- Alternative route discovery using real OSRM waypoint routes.
- Alternative route distance and time comparisons.
- `Opened`, `Use alternative`, and `RECOMMENDED` route states.
- Runtime persistence for blocked-road data.
- JSON API endpoints for routing, search, reverse geocoding, road data, and journey details.

## Project structure

```text
Prolog/
├── app_server.pl                 # Local and hosted HTTP server entrypoint
├── Dockerfile                    # Container image definition
├── render.yaml                   # Render free-service configuration
├── .dockerignore                 # Files excluded from container builds
├── README.md
├── .vscode/
│   └── settings.json
├── backend/
│   ├── smart_route_api.pl        # Routing engine and HTTP API handlers
│   ├── data/
│   │   └── blocked_roads.pl      # Runtime-persisted blocked-road facts
│   └── logs/
│       └── server.log            # Runtime diagnostics, created when needed
├── frontend/
│   └── route_finder_ui.html      # Single-page browser interface
└── tools/
    └── diagnostics/              # Temporary development request scripts
```

## Requirements

For local development:

- SWI-Prolog with HTTP libraries available.
- A modern browser with JavaScript and geolocation support.
- Internet access for Nominatim, OSRM, and OpenStreetMap tiles.

The SWI-Prolog executable used during development was:

```text
C:\Program Files\swipl\bin\swipl.exe
```

## Run locally

Open PowerShell in the project root:

```powershell
& 'C:\Program Files\swipl\bin\swipl.exe' -q -s app_server.pl -g start
```

The local server listens on:

```text
http://localhost:8080/
```

The `start` goal opens the application in the default browser.

To load the server without opening a browser:

```powershell
& 'C:\Program Files\swipl\bin\swipl.exe' -q -s app_server.pl -g start_server
```

The server uses the `PORT` environment variable when it is set. Otherwise it uses port `8080`.

Example:

```powershell
$env:PORT = '8099'
& 'C:\Program Files\swipl\bin\swipl.exe' -q -s app_server.pl -g start_server
```

## Routing behavior

### Coordinate-based routing

When the browser has coordinates for the start and destination, the backend requests a route from OSRM. The response includes:

- Route path labels.
- Distance in kilometres.
- Estimated duration in minutes.
- Route geometry for Leaflet.
- Journey steps when available.

### Route preferences

- **Fastest** selects the candidate with the lowest returned duration.
- **Shortest** selects the candidate with the lowest returned distance.

If OSRM returns only one candidate, both preferences necessarily produce the same route. The application does not invent a route simply to make the values look different.

### Alternative routes

The public OSRM service does not guarantee a complete list of every possible path. When the user opens **Manage road status**, the frontend requests several waypoint-constrained routes through different real map corridors:

1. The current route.
2. A north-east corridor.
3. An east corridor.
4. A west corridor.
5. A south-west corridor.

Only successful OSRM responses are displayed. Duplicate routes are removed by comparing their distances. Each candidate shows its distance, duration, and additional distance/time compared with the shortest candidate.

Selecting **Use alternative**:

1. Keeps the existing start location.
2. Keeps the existing destination.
3. Sends the selected waypoint to OSRM.
4. Recalculates the route.
5. Updates the map geometry and metrics.
6. Marks the selected route as `Opened`.

The shortest candidate is always labeled `Best route` and `RECOMMENDED`. `Opened` identifies the route currently being used; it does not necessarily mean that route is the shortest.

## Travel modes

The interface supports:

- **On foot** — duration is calculated from the route distance using 5 km/h.
- **Vehicle** — duration uses the routing provider's estimate.

The current OSRM endpoint used by this project is the public driving profile. Walking mode currently changes the displayed estimate and route messaging, but a production walking deployment should use a walking-capable routing profile or routing engine.

## Live navigation

Clicking **View journey** starts browser geolocation tracking when route geometry is available.

During navigation, the application:

- Moves the current-position marker.
- Calculates the remaining distance from the nearest route geometry point.
- Updates the route summary and road network status.
- Zooms the map toward the current position.
- Detects arrival within approximately 50 metres.

Clicking **Stop navigation** clears the geolocation watcher and resets the road status to:

```text
No Journey selected
```

This is not full turn-by-turn navigation. Voice instructions, traffic-aware rerouting, and automatic off-route recovery are not currently implemented.

## API endpoints

All endpoints are served by the local Prolog server.

### `POST /api/route`

Coordinate request:

```json
{
  "start_coord": {
    "lat": 6.9271,
    "lon": 79.8612,
    "name": "Start"
  },
  "destination_coord": {
    "lat": 6.9471,
    "lon": 79.9012,
    "name": "Destination"
  },
  "destination": "Destination",
  "preference": "fastest",
  "travel_mode": "vehicle"
}
```

Supported preference values:

```text
fastest
shortest
```

Supported travel-mode values:

```text
foot
vehicle
```

Waypoint request for an alternative route:

```json
{
  "start_coord": {
    "lat": 6.9271,
    "lon": 79.8612
  },
  "destination_coord": {
    "lat": 6.9471,
    "lon": 79.9012
  },
  "via_coord": {
    "lat": 6.9371,
    "lon": 79.8848,
    "name": "Selected alternative"
  },
  "preference": "shortest",
  "travel_mode": "vehicle"
}
```

Successful responses include:

```json
{
  "ok": true,
  "path": ["Start", "Destination"],
  "distance": 8.0,
  "minutes": 11,
  "stops": 0,
  "geometry": [
    { "lat": 6.9271, "lon": 79.8612 }
  ]
}
```

### `GET /api/search?q=...`

Searches Nominatim through the Prolog backend and returns place suggestions.

### `GET /api/reverse?lat=...&lon=...`

Reverse-geocodes coordinates through Nominatim.

### `GET /api/roads`

Returns known fallback-graph roads, coordinates, and blocked state. The current alternative-route panel prefers real OSRM waypoint routes when coordinate routing is available.

### `/api/blocked`

Reads or changes runtime blocked-road state. Blocked-road data is stored in `backend/data/blocked_roads.pl`.

### `/api/details`

Returns available journey-step information. OSRM steps are used when available; the local graph is used as a fallback.

## Runtime data and logs

Blocked roads are persisted as Prolog facts in:

```text
backend/data/blocked_roads.pl
```

Server diagnostics are written to:

```text
backend/logs/server.log
```

These are runtime files, not authoritative live road-closure data. The application does not currently consume a verified real-time Colombo road-incident feed.

## Free hosting with Render

The repository includes a Docker deployment configuration for Render's free web-service plan.

### Deploy from GitHub

1. Push the project to a GitHub repository.
2. Sign in to Render.
3. Select **New > Blueprint**.
4. Connect the GitHub repository.
5. Render detects `render.yaml`.
6. Wait for the Docker build and deployment to finish.
7. Open the public URL provided by Render.

The container starts with:

```text
swipl -q -s app_server.pl -g start_server
```

The server binds to `0.0.0.0` and reads Render's `PORT` value automatically.

The free Render service may sleep after inactivity. The first request after sleeping can take longer while the service starts.

### Local Docker build

If Docker Desktop is running:

```powershell
docker build -t smart-route-finder:local .
docker run --rm -e PORT=8080 -p 8080:8080 smart-route-finder:local
```

Then open:

```text
http://localhost:8080/
```

## External service limitations

The project uses public OpenStreetMap services without API keys. They are useful for development and small demonstrations, but they have important limits:

- Public OSRM and Nominatim endpoints are rate-limited.
- They do not provide guaranteed uptime or a service-level agreement.
- Nominatim usage should remain respectful and identifiable.
- OSRM does not provide every mathematically possible route.
- OSRM's public driving profile does not provide authoritative live road closures.
- OpenStreetMap data may be incomplete or out of date.
- Hosted services may restrict or suspend heavy public traffic.

For a larger deployment, host a routing engine privately or use a provider with a documented quota and service agreement. A self-hosted Valhalla or OSRM instance avoids per-request API billing but requires map-data downloads, storage, memory, and maintenance.

## Troubleshooting

### Port already in use

Find the process using the port and stop it before starting another server:

```powershell
Get-NetTCPConnection -LocalPort 8080 -State Listen
```

Use a different port instead:

```powershell
$env:PORT = '8099'
& 'C:\Program Files\swipl\bin\swipl.exe' -q -s app_server.pl -g start_server
```

### Route provider unavailable

The frontend displays a route error when OSRM or geocoding is unavailable. Coordinate routing may fall back to the local Prolog graph where a matching graph location exists.

### Location search does not work

Check that:

- The application is opened through `http://localhost:8080`, not directly as a local file.
- The browser has internet access.
- The destination suggestion is selected or the destination text is valid.
- Nominatim has not rate-limited the request.

### Browser location is unavailable

Allow location access for the site, or type and select a start location manually.

## Development notes

- `app_server.pl` is the only recommended server entrypoint.
- The frontend is intentionally kept as one HTML file for this small project.
- Runtime files belong under `backend/data` and `backend/logs`.
- Temporary diagnostics belong under `tools/diagnostics`.
- Do not commit API keys, private map data, or credentials.
- Public routing results should be treated as estimates, not authoritative traffic or road-closure information.
