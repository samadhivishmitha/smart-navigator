:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(heaps)).
:- use_module(library(pairs)).

% HTTP client + URI helpers used by the Google Directions adapter below
:- use_module(library(http/http_open)).
:- use_module(library(uri)).
:- use_module(library(http/http_parameters)).


:- dynamic blocked_road/2.

% --- FIX (warning @ line 19): resolve paths relative to THIS file's own
% directory instead of the process's current working directory. This
% removes the dependency on the deprecated source_search_working_directory
% flag and works no matter where `swipl` is launched from.
:- dynamic source_dir/1.
:- prolog_load_context(directory, ThisDir),
   asserta(source_dir(ThisDir)).

% Persisted blocked roads file (written/read as Prolog facts).
% smart_route_api.pl lives directly in backend/, and blocked_roads.pl lives
% in backend/data/, so data/ is a sibling directory of this source file.
blocked_roads_file(File) :-
    source_dir(Dir),
    atomic_list_concat([Dir, '/data/blocked_roads.pl'], File).

% Load persisted blocked roads if the file exists
:- ( blocked_roads_file(File), exists_file(File) -> consult(File) ; true ).

:- http_handler(root(api/route), route_api, []).
:- http_handler(root(api/blocked), blocked_api, []).
:- http_handler(root(api/roads), roads_api, []).
:- http_handler(root(api/details), details_api, []).
:- http_handler(root(api/search), search_api, []).
:- http_handler(root(api/reverse), reverse_api, []).

% --- FIX (warning @ line 550): clauses of details_api/1 are intentionally
% split (a GET clause and a POST clause) with other predicates defined in
% between. This directive tells Prolog that's expected, silencing the
% "not together in source-file" warning without reordering anything.
:- discontiguous details_api/1.

% Default blocked roads for demo (will be overridden by persisted file if present)
blocked_road(rajagiriya, maradana).

road(kelaniya, wattala, 4.2, 12).
road(wattala, borella, 5.1, 16).
road(borella, colombo_fort, 4.8, 14).
road(kelaniya, rajagiriya, 6.0, 19).
road(rajagiriya, borella, 3.0, 10).
road(rajagiriya, maradana, 4.5, 15).
road(maradana, colombo_fort, 2.0, 7).
road(wattala, colombo_fort, 9.2, 27).

coordinates(kelaniya, 0, 7).
coordinates(wattala, 2, 5).
coordinates(rajagiriya, 5, 6).
coordinates(borella, 5, 3).
coordinates(maradana, 7, 2).
coordinates(colombo_fort, 9, 0).

% Server startup is handled by app_server.pl to avoid starting multiple servers.
% Use app_server:start to launch the application and open the frontend UI.

% route_api/1 handles POST JSON requests with {start, destination, preference}.
% If the request is GET, return a short informational JSON to avoid an HTTP 500
% when someone loads the endpoint directly in a browser.
route_api(Request) :-
    format(user_error, 'DEBUG route_api request: ~w~n', [Request]),
    % Wrap the handler in a catch so unexpected server-side errors return a
    % structured JSON response and are logged to the server console for
    % easier debugging (prevents large HTML error dumps in the browser).
    catch(
        (
            % If this is a browser GET (or any GET), show a helpful message.
            ( memberchk(method(get), Request) ->
                reply_json_dict(_{ok:true, message: "POST JSON to this endpoint with keys: start, destination, preference (fastest|shortest). Alternatively include start_coord and/or destination_coord with {lat,lon,name}."})
            ;
                % Expect a JSON POST; parse safely and return a friendly error on failure.
                ( catch(http_read_json_dict(Request, Data), ParseError,
                        ( format(user_error, 'Route JSON parse error: ~w~n', [ParseError]),
                          reply_json_dict(_{ok:false, message:"Bad request: expecting JSON POST body."}),
                          !, fail ))
                ->  true
                ;   !
                ),
                % Extract optional coordinate payloads in a tolerant way.
                ( get_dict(start_coord, Data, SC0) -> SC = SC0 ; SC = null ),
                ( get_dict(destination_coord, Data, DC0) -> DC = DC0 ; DC = null ),
                ( get_dict(via_coord, Data, VC0) -> VC = VC0 ; VC = null ),
                ( get_dict(preference, Data, PrefRaw) -> json_atom(PrefRaw, Preference) ; Preference = fastest ),
                % If coordinates present, route using OSRM/Google by coordinates
                ( is_dict(SC) ->
                    ( get_dict(lat, SC, SL), get_dict(lon, SC, SLon) -> true ; ( get_dict(latitude, SC, SL), get_dict(longitude, SC, SLon) ) ),
                    % destination coordinates provided?
                    ( is_dict(DC) -> ( get_dict(lat, DC, DL), get_dict(lon, DC, DLon) -> true ; ( get_dict(latitude, DC, DL), get_dict(longitude, DC, DLon) ) ) ;
                      % else destination is an atom name: resolve it to real map coordinates when possible,
                      % then fall back to the demo graph node coordinate if it is a known internal location.
                      ( get_dict(destination, Data, DestRaw) -> json_atom(DestRaw, DestinationAtom), resolve_destination_coord(DestinationAtom, DL, DLon) ; reply_json_dict(_{ok:false, message:"Destination missing."}), !, fail )
                    ),
                    % call coords-based OSRM/Google adapter
                    (   ( is_dict(VC),
                          get_dict(lat, VC, VL),
                          get_dict(lon, VC, VLon),
                          osrm_route_coords_via(SL, SLon, VL, VLon, DL, DLon, PathC, Distance, Minutes, Geometry),
                          Alternatives = []
                        ; \+ is_dict(VC),
                          osrm_route_coords_preferred(SL, SLon, DL, DLon, Preference, PathC, Distance, Minutes, Geometry, _Steps),
                          Alternatives = [_{index:0, path:PathC, distance:Distance, minutes:Minutes, geometry:Geometry}]
                        )
                    ->  length(PathC, Length), Stops is max(0, Length - 2), reply_json_dict(_{ok:true, path:PathC, distance:Distance, minutes:Minutes, stops:Stops, geometry:Geometry, alternatives:Alternatives})
                    ; ( google_api_key(_K), google_route_coords(SL, SLon, DL, DLon, PathG, DistanceG, MinutesG, GeometryG, _StepsG) -> length(PathG, Lg), Stops is max(0, Lg-2), reply_json_dict(_{ok:true, path:PathG, distance:DistanceG, minutes:MinutesG, stops:Stops, geometry:GeometryG})
                      ; % Fall back to local A* by mapping coords to nearest node (approx)
                        nearest_node(SL, SLon, StartNode), ( get_dict(destination, Data, DestRaw) -> json_atom(DestRaw, DestinationAtom) ; reply_json_dict(_{ok:false, message:"Destination missing."}), !, fail ), ( a_star(StartNode, DestinationAtom, Preference, PathA) -> path_metrics(PathA, Distance, Minutes), length(PathA, LA), Stops is max(0, LA-2), ( path_geometry(PathA, GeometryA) -> reply_json_dict(_{ok:true, path:PathA, distance:Distance, minutes:Minutes, stops:Stops, geometry:GeometryA}) ; reply_json_dict(_{ok:true, path:PathA, distance:Distance, minutes:Minutes, stops:Stops}) ) ; reply_json_dict(_{ok:false, message:"No available route was found."}) )
                      )
                    )
                ; % No coordinate start provided: use existing atom-based flow
                    ( get_dict(start, Data, StartRaw) -> json_atom(StartRaw, Start) ; reply_json_dict(_{ok:false, message:"Start missing."}), !, fail ),
                    ( get_dict(destination, Data, DestRaw2) -> json_atom(DestRaw2, Destination) ; reply_json_dict(_{ok:false, message:"Destination missing."}), !, fail ),
                    ( get_dict(preference, Data, P0) -> json_atom(P0, Preference) ; true ),
                    (   Start == Destination
                    ->  reply_json_dict(_{ok:false, message:"Choose two different locations."})
                    ;   ( \+ coordinates(Start,_,_)
                        ->  reply_json_dict(_{ok:false, message: "Unknown start location."})
                        ; \+ coordinates(Destination,_,_)
                        ->  reply_json_dict(_{ok:false, message: "Unknown destination location."})
                        ; \+ member(Preference, [fastest, shortest])
                        ->  reply_json_dict(_{ok:false, message: "Invalid preference; choose 'fastest' or 'shortest'."})
                        ; find_best_route(Start, Destination, Preference, Path0, Distance, Minutes)
                        ->  response_path(Path0, Start, Destination, Path),
                            length(Path, Length),
                            Stops is max(0, Length - 2),
                            % Build geographic geometry for the path so the frontend can draw it on a map.
                            (   path_geometry(Path, Geometry)
                            ->  reply_json_dict(_{ok:true, path:Path, distance:Distance,
                                                  minutes:Minutes, stops:Stops, geometry:Geometry})
                            ;   reply_json_dict(_{ok:true, path:Path, distance:Distance,
                                                  minutes:Minutes, stops:Stops})
                            )
                        ;   reply_json_dict(_{ok:false,
                                              message:"No available route was found."})
                        )
                    )
                )
            )
        ),
        Err,
        ( format(user_error, 'Route API exception: ~w~n', [Err]),
          message_to_string(Err, ErrMsg0),
          log_server_event(route_error(ErrMsg0)),
          format(atom(ErrMsg), '~w', [ErrMsg0]),
          reply_json_dict(_{ok:false, message:"Internal server error", detail:ErrMsg})
        )
    ).

% Blocked-roads management API
blocked_api(Request) :-
    memberchk(method(get), Request), !,
    findall(_{from:From, to:To}, blocked_road(From, To), Blocks),
    reply_json_dict(_{ok:true, blocked:Blocks}).
blocked_api(Request) :-
    http_read_json_dict(Request, Data),
    (   get_dict(action, Data, Action),
        get_dict(from, Data, FromRaw),
        get_dict(to, Data, ToRaw)
    ->  json_atom(FromRaw, From),
        json_atom(ToRaw, To),
        ( (Action == "block" ; Action == block)
        ->  ( blocked_between(From,To)
            -> reply_json_dict(_{ok:false, message:"Already blocked."})
            ;  assertz(blocked_road(From,To)), persist_blocked_roads, reply_json_dict(_{ok:true, message:"Road blocked."})
            )
        ; (Action == "unblock" ; Action == unblock)
        ->  ( blocked_between(From,To)
            -> retractall(blocked_road(From,To)), retractall(blocked_road(To,From)), persist_blocked_roads, reply_json_dict(_{ok:true, message:"Road unblocked."})
            ;  reply_json_dict(_{ok:false, message:"Road was not blocked."})
            )
        ; reply_json_dict(_{ok:false, message:"Unknown action; use 'block' or 'unblock'."})
        )
    ; reply_json_dict(_{ok:false, message:"Bad request. Expecting JSON with keys 'from','to','action'."})
    ).

% Persist current blocked_road facts to disk so blocks survive restarts.
persist_blocked_roads :-
    blocked_roads_file(File),
    setup_call_cleanup(open(File, write, Out, [type(text)]),
        (   forall(blocked_road(A,B), format(Out, ':- dynamic blocked_road/2.~nblocked_road(~w, ~w).~n', [A,B])) ),
        close(Out)).

% roads_api returns all known roads and whether they are currently blocked.
roads_api(Request) :-
    memberchk(method(get), Request), !,
    findall(_{from:From, to:To, distance:Dist, minutes:Min, blocked:Blocked,
              from_coord:FromCoord, to_coord:ToCoord},
            ( road(From,To,Dist,Min),
              ( blocked_between(From,To) -> Blocked = true ; Blocked = false ),
              node_to_latlon(From, FromCoord),
              node_to_latlon(To, ToCoord)
            ),
            Roads),
    reply_json_dict(_{ok:true, roads:Roads}).

json_atom(Value, Atom) :-
    ( string(Value) ->
        normalize_name(Value, NormalizedString),
        atom_string(Atom, NormalizedString)
    ; Atom = Value ).

% Resolve a destination label to a real map coordinate when possible.
% This is used for real current-location routing: a user location is given in
% lat/lon, and destination names like "Rajagiriya" or "Colombo Fort" are
% geocoded through Nominatim before the OSRM route is requested.
resolve_destination_coord(DestinationAtom, Lat, Lon) :-
    ( atom(DestinationAtom) -> atom_string(DestinationAtom, DestS0) ; format(string(DestS0), '~w', [DestinationAtom]) ),
    replace_underscore_with_space(DestS0, DestLabel),
    ( geocode_place_name(DestLabel, Lat, Lon) -> true
    ; node_to_latlon(DestinationAtom, _{lat:Lat, lon:Lon})
    ).

geocode_place_name(Name, Lat, Lon) :-
    % Ask Nominatim for a real map coordinate and accept the first result.
    uri_encoded(query_value, Name, EncName),
    format(string(URL), 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=~w', [EncName]),
    catch((
        http_open(URL, Stream, [timeout(10), request_header('User-Agent','SmartRouteFinder/1.0')]),
        json_read_dict(Stream, Json),
        close(Stream)
    ), _E, fail),
    ( is_list(Json), Json = [First|_] -> true ; ( is_dict(Json) -> First = Json ; fail ) ),
    get_dict(lat, First, LatVal), number(LatVal),
    get_dict(lon, First, LonVal), number(LonVal),
    Lat = LatVal, Lon = LonVal.

% Normalize a human-friendly name into the canonical atom form used by the
% road graph. Examples:
%  "Colombo Fort" -> "colombo_fort"
%  "Kelaniya"     -> "kelaniya"
% This keeps the backend tolerant of UI labels and other input sources.
normalize_name(String, Normalized) :-
    string_lower(String, Lower),
    replace_spaces_and_hyphens(Lower, Temp),
    string_chars(Temp, Chars),
    include(allowed_char, Chars, CleanChars),
    string_chars(Normalized, CleanChars).

replace_spaces_and_hyphens(String, Out) :-
    string_chars(String, Chars),
    maplist(replace_sep, Chars, OutChars),
    string_chars(Out, OutChars).

replace_sep(' ', '_') :- !.
replace_sep('-', '_') :- !.
replace_sep(Char, Char).

allowed_char(Char) :-
    char_type(Char, alnum) ; Char = '_'.


find_best_route(Start, Destination, Preference, Path, Distance, Minutes) :-
    % Prefer OSRM (free OpenStreetMap-based routing). If that fails, try
    % Google Directions if a key is configured; otherwise fall back to the
    % local built-in graph.
    % --- FIX (warning @ line 244): GeometryOSRM was bound but never used
    % again in this clause. Renamed to _GeometryOSRM (leading underscore)
    % to tell Prolog this is intentionally unused, without changing logic.
    (   catch(osrm_route(Start, Destination, Preference, _PathOSRM, DistOSRM, MinOSRM, _GeometryOSRM, _Steps), _E, fail)
    ->  Path = [Start, Destination], Distance = DistOSRM, Minutes = MinOSRM
    ;   ( google_api_key(_Key)
        ->  ( google_route(Start, Destination, Preference, PathG, DistG, MinG)
            ->  Path = PathG, Distance = DistG, Minutes = MinG
            ;   a_star(Start, Destination, Preference, PathA), path_metrics(PathA, Distance, Minutes)
            )
        ;   a_star(Start, Destination, Preference, PathA), path_metrics(PathA, Distance, Minutes)
        )
    ).

response_path([], Start, Destination, [Start, Destination]) :- !.
response_path(Path, _Start, _Destination, Path).

% ---- Google Directions adapter ----
% The adapter calls the Google Directions API and converts the response into
% the same (Path, Distance (km), Minutes) shape used by the local engine.
% It is intentionally conservative: any error from Google results in failure so
% callers can fall back to the local graph implementation.

% google_api_key(-Key) reads the API key from the environment variable
% GOOGLE_MAPS_API_KEY. Set this in your OS if you want the server to use
% Google Directions.
google_api_key(Key) :-
    getenv('GOOGLE_MAPS_API_KEY', Key),
    Key \= ''.

% google_route(+StartAtom, +DestAtom, +Preference, -Path, -DistanceKm, -Minutes)
% StartAtom/DestAtom may be atoms like kelaniya or Columbo_Fort; they are
% converted into a human-friendly address string for the Directions API.
google_route(Start, Destination, Preference, Path, DistanceKm, Minutes) :-
    google_api_key(Key),
    atom_string(Start, StartS0),
    atom_string(Destination, DestS0),
    % Prepare readable address strings for Google: replace underscores with spaces.
    maplist(replace_underscore_with_space, [StartS0, DestS0], [StartAddr, DestAddr]),
    % URL-encode query values
    uri_encoded(query_value, StartAddr, EncStart),
    uri_encoded(query_value, DestAddr, EncDest),
    % Use driving mode. For 'fastest' request traffic-aware duration (departure_time=now).
    ( Preference == fastest -> TrafficOpt = '&departure_time=now' ; TrafficOpt = '' ),
    format(string(URL),
           'https://maps.googleapis.com/maps/api/directions/json?origin=~w&destination=~w&mode=driving~w&key=~w',
           [EncStart, EncDest, TrafficOpt, Key]),
    catch(
        (   http_open(URL, Stream, [ssl([verify_certificate(false)]), request_header('User-Agent','SmartRouteFinder/1.0')]),
            json_read_dict(Stream, Json),
            close(Stream)
        ),
        _E,
        fail
    ),
    % Require OK status and at least one route
    ( Json.status == "OK", Json.routes \= [] ),
    Routes = Json.routes,
    Routes = [Route|_],
    Legs = Route.legs,
    % Sum distances and choose duration (traffic-aware if present and requested)
    sum_legs_distance_meters(Legs, TotalMeters),
    ( Preference == fastest -> sum_legs_duration_traffic_seconds(Legs, TotalSeconds) ; sum_legs_duration_seconds(Legs, TotalSeconds) ),
    DistanceKm is TotalMeters / 1000,
    Minutes is round(TotalSeconds / 60),
    % Build a simple human-readable path: use start_address, via waypoint addresses (if any), end_address
    ( get_dict(start_address, Route, StartAddrFull) -> true ; StartAddrFull = StartAddr ),
    ( get_dict(end_address, Route, EndAddrFull) -> true ; EndAddrFull = DestAddr ),
    % Some routes include via_waypoint addresses in legs or in route.via_waypoints; we'll keep it simple.
    Path = [StartAddrFull, EndAddrFull].

replace_underscore_with_space(S, Out) :-
    split_string(S, "_", "", Parts),
    atomic_list_concat(Parts, ' ', A),
    atom_string(OutA, A),
    ( string(OutA) -> Out = OutA ; Out = S ).

sum_legs_distance_meters(Legs, Sum) :-
    maplist(leg_distance_meters, Legs, MetersList),
    sum_list(MetersList, Sum).

leg_distance_meters(Leg, Meters) :-
    ( get_dict(distance, Leg, D) -> Meters = D.value ; Meters = 0 ).

sum_legs_duration_seconds(Legs, Sum) :-
    maplist(leg_duration_seconds, Legs, SecondsList),
    sum_list(SecondsList, Sum).

leg_duration_seconds(Leg, Sec) :-
    ( get_dict(duration, Leg, D) -> Sec = D.value ; Sec = 0 ).

% If duration_in_traffic is available use it; fall back to duration.
sum_legs_duration_traffic_seconds(Legs, Sum) :-
    maplist(leg_duration_traffic_seconds, Legs, SecondsList),
    sum_list(SecondsList, Sum).

leg_duration_traffic_seconds(Leg, Sec) :-
    ( get_dict(duration_in_traffic, Leg, D) -> Sec = D.value ; ( get_dict(duration, Leg, DD) -> Sec = DD.value ; Sec = 0 ) ).

% ---- OSRM adapter (free routing using OpenStreetMap)
% Uses the public OSRM demo server (router.project-osrm.org) to obtain
% route geometry and metrics. This is suitable for demos but not for
% production traffic at scale — consider hosting OSRM for heavy use.

osrm_route(Start, Destination, Preference, Path, DistanceKm, Minutes, Geometry, Steps) :-
    % Convert node atoms to lat/lon pairs
    node_to_latlon(Start, StartPoint), node_to_latlon(Destination, EndPoint),
    StartPoint = _{lat:Lat1, lon:Lon1}, EndPoint = _{lat:Lat2, lon:Lon2},
    osrm_route_coords_preferred(Lat1, Lon1, Lat2, Lon2, Preference, Path, DistanceKm, Minutes, Geometry, Steps).

% osrm_route_coords(+StartLat,+StartLon,+EndLat,+EndLon,-Path,-DistanceKm,-Minutes,-Geometry,-Steps)
osrm_route_coords_preferred(SLat, SLon, DLat, DLon, Preference, PathOut, DistanceKm, Minutes, Geometry, Steps) :-
    format(string(Coord), '~w,~w;~w,~w', [SLon,SLat,DLon,DLat]),
    format(string(URL), 'https://router.project-osrm.org/route/v1/driving/~w?overview=full&geometries=geojson&steps=true&alternatives=true', [Coord]),
    catch((http_open(URL, Stream, [request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), _E, fail),
    get_dict(code, Json, "Ok"),
    get_dict(routes, Json, Routes),
    Routes \= [],
    choose_osrm_route(Routes, Preference, Route),
    osrm_route_result(Route, SLat, SLon, DLat, DLon, PathOut, DistanceKm, Minutes, Geometry, Steps).

choose_osrm_route([Route|Routes], Preference, Selected) :-
    append([Route|Routes], [], AllRoutes),
    map_list_to_pairs(osrm_route_score(Preference), AllRoutes, Scored),
    keysort(Scored, [_-Selected|_]).

osrm_route_score(shortest, Route, Score) :-
    get_dict(distance, Route, Score).
osrm_route_score(fastest, Route, Score) :-
    get_dict(duration, Route, Score).

osrm_route_result(Route, SLat, SLon, DLat, DLon, PathOut, DistanceKm, Minutes, Geometry, Steps) :-
    get_dict(distance, Route, DistanceMeters),
    get_dict(duration, Route, DurationSeconds),
    DistanceKm is DistanceMeters / 1000,
    Minutes is round(DurationSeconds / 60),
    ( get_dict(geometry, Route, Geo), get_dict(coordinates, Geo, Coords0) -> maplist(osrm_coord_to_point, Coords0, Geometry) ; Geometry = [] ),
    ( nominatim_reverse(SLat, SLon, StartName) -> true ; StartName = 'Start' ),
    ( nominatim_reverse(DLat, DLon, EndName) -> true ; EndName = 'Destination' ),
    PathOut = [StartName, EndName],
    ( get_dict(legs, Route, Legs),
      findall(StepInfo, (member(Leg, Legs), get_dict(steps, Leg, Steps0), member(S, Steps0), step_summary(S, StepInfo)), Steps)
    ; Steps = []
    ).

osrm_route_coords(SLat, SLon, DLat, DLon, PathOut, DistanceKm, Minutes, Geometry, Steps) :-
    % OSRM expects lon,lat pairs
    format(string(Coord), '~w,~w;~w,~w', [SLon,SLat,DLon,DLat]),
    format(string(URL), 'https://router.project-osrm.org/route/v1/driving/~w?overview=full&geometries=geojson&steps=true', [Coord]),
    catch((http_open(URL, Stream, [request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), _E, fail),
    ( get_dict(code, Json, Code), Code == "Ok", Json.routes \= [] ),
    Json.routes = [Route|_],
    get_dict(distance, Route, DistanceMeters),
    get_dict(duration, Route, DurationSeconds),
    DistanceKm is DistanceMeters / 1000,
    Minutes is round(DurationSeconds / 60),
    ( get_dict(geometry, Route, Geo),
      get_dict(coordinates, Geo, Coords0)
    -> Coords = Coords0
    ;  Coords = []
    ),
    maplist(osrm_coord_to_point, Coords, Geometry),
    % Try to reverse-geocode start/end to readable names via Nominatim (best-effort)
    ( nominatim_reverse(SLat, SLon, StartName) -> true ; StartName = 'Start' ),
    ( nominatim_reverse(DLat, DLon, EndName) -> true ; EndName = 'Destination' ),
    PathOut = [StartName, EndName],
    ( get_dict(legs, Route, Legs),
      findall(StepInfo, (member(Leg, Legs), get_dict(steps, Leg, Steps0), member(S, Steps0), step_summary(S, StepInfo)), Steps)
    ; Steps = []
    ).

osrm_coord_to_point([Lon,Lat], _{lat:Lat, lon:Lon}).

osrm_route_coords_via(SLat, SLon, VLat, VLon, DLat, DLon, PathOut, DistanceKm, Minutes, Geometry) :-
    format(string(Coord), '~w,~w;~w,~w;~w,~w', [SLon,SLat,VLon,VLat,DLon,DLat]),
    format(string(URL), 'https://router.project-osrm.org/route/v1/driving/~w?overview=full&geometries=geojson&steps=true', [Coord]),
    catch((http_open(URL, Stream, [request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), _E, fail),
    get_dict(code, Json, "Ok"),
    get_dict(routes, Json, [Route|_]),
    get_dict(distance, Route, DistanceMeters),
    get_dict(duration, Route, DurationSeconds),
    DistanceKm is DistanceMeters / 1000,
    Minutes is round(DurationSeconds / 60),
    get_dict(geometry, Route, Geo),
    get_dict(coordinates, Geo, Coords),
    maplist(osrm_coord_to_point, Coords, Geometry),
    ( nominatim_reverse(SLat, SLon, StartName) -> true ; StartName = 'Start' ),
    ( nominatim_reverse(DLat, DLon, EndName) -> true ; EndName = 'Destination' ),
    PathOut = [StartName, EndName].

osrm_route_coords_alternatives(SLat, SLon, DLat, DLon, RouteIndex, PathOut, DistanceKm, Minutes, Geometry, Alternatives) :-
    format(string(Coord), '~w,~w;~w,~w', [SLon,SLat,DLon,DLat]),
    format(string(URL), 'https://router.project-osrm.org/route/v1/driving/~w?overview=full&geometries=geojson&steps=true&alternatives=true', [Coord]),
    catch((http_open(URL, Stream, [request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), _E, fail),
    get_dict(code, Json, "Ok"),
    get_dict(routes, Json, Routes),
    Routes \= [],
    route_candidates(Routes, SLat, SLon, DLat, DLon, Candidates),
    length(Candidates, Count),
    MaxIndex is Count - 1,
    SelectedIndex is max(0, min(RouteIndex, MaxIndex)),
    nth0(SelectedIndex, Candidates, Selected),
    Selected = _{path:PathOut, distance:DistanceKm, minutes:Minutes, geometry:Geometry},
    Alternatives = Candidates.

route_candidates(Routes, SLat, SLon, DLat, DLon, Candidates) :-
    ( nominatim_reverse(SLat, SLon, StartName) -> true ; StartName = 'Start' ),
    ( nominatim_reverse(DLat, DLon, EndName) -> true ; EndName = 'Destination' ),
    route_candidates(Routes, StartName, EndName, 0, Candidates).

route_candidates([], _StartName, _EndName, _Index, []).
route_candidates([Route|Rest], StartName, EndName, Index, [Candidate|Candidates]) :-
    get_dict(distance, Route, DistanceMeters),
    get_dict(duration, Route, DurationSeconds),
    DistanceKm is DistanceMeters / 1000,
    Minutes is round(DurationSeconds / 60),
    ( get_dict(geometry, Route, Geo), get_dict(coordinates, Geo, Coords0) -> maplist(osrm_coord_to_point, Coords0, Geometry) ; Geometry = [] ),
    Candidate = _{index:Index, path:[StartName,EndName], distance:DistanceKm, minutes:Minutes, geometry:Geometry},
    NextIndex is Index + 1,
    route_candidates(Rest, StartName, EndName, NextIndex, Candidates).

step_summary(Step, _{distance: D, duration: Dur, name: Name, instruction: Instr}) :-
    ( get_dict(distance, Step, D) -> true ; D = 0 ),
    ( get_dict(duration, Step, Dur) -> true ; Dur = 0 ),
    ( get_dict(name, Step, Name) -> true ; Name = "" ),
    ( get_dict(maneuver, Step, M), get_dict(instruction, M, Instr) -> true ; Instr = "" ).

% Simple Nominatim reverse geocode (best-effort). Respects demo usage limits.
nominatim_reverse(Lat, Lon, DisplayName) :-
    format(string(URL), 'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=~w&lon=~w', [Lat, Lon]),
    catch((http_open(URL, Stream, [timeout(10), request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), _E, fail),
    ( get_dict(display_name, Json, DN) -> DisplayName = DN ; fail ).

% ---- Search & reverse proxy endpoints to avoid browser-side direct calls to
% Nominatim. These endpoints forward requests server-side with a proper
% User-Agent header and a timeout so the app behaves well with the public API.
search_api(Request) :-
    memberchk(method(get), Request),
    ( request_query_value(Request, q, Q) -> true
    ; reply_json_dict(_{ok:false, message:'Missing q parameter'}), !, fail
    ),
    % Re-encode query value for upstream URL
    uri_encoded(query_value, Q, QE),
    format(string(URL), 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&q=~w', [QE]),
    catch((http_open(URL, Stream, [timeout(10), request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), E,
          ( format(user_error, 'Nominatim search failed: ~w~n', [E]), reply_json_dict(_{ok:false, message:'Search failed'}), !, fail )),
    reply_json_dict(_{ok:true, results:Json}).

reverse_api(Request) :-
    memberchk(method(get), Request),
    ( request_query_value(Request, lat, LatS),
      request_query_value(Request, lon, LonS)
    -> true
    ; reply_json_dict(_{ok:false, message:'Missing lat/lon'}), !, fail
    ),
    format(string(URL), 'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=~w&lon=~w', [LatS, LonS]),
    catch((http_open(URL, Stream, [timeout(10), request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream)), E,
          ( format(user_error, 'Nominatim reverse failed: ~w~n', [E]), reply_json_dict(_{ok:false, message:'Reverse geocode failed'}), !, fail )),
    ( get_dict(display_name, Json, DN) -> reply_json_dict(_{ok:true, display_name:DN}) ; reply_json_dict(_{ok:false, message:'No display_name returned'}) ).

request_query_value(Request, Key, Value) :-
    memberchk(search(Query), Request),
    ( Query =.. [Key, Value]
    ; Query = List, is_list(List), member(Pair, List), Pair = (Key=Value)
    ; Query = (Key=Value)
    ),
    !.

% ---- Details endpoint ----
% Returns a list of step-by-step instructions for a route between two nodes.
% POST JSON { start, destination, preference }.

details_api(Request) :-
    memberchk(method(get), Request), !,
    % If query parameters are present (start/destination), act like a GET-based details call.
    ( memberchk(search(Query), Request)
    -> ( format(string(QueryString), '~w', [Query]),
         uri_query_components(QueryString, Pairs),
        ( memberchk(start=StartRaw, Pairs), memberchk(destination=DestRaw, Pairs)
        -> ( ( memberchk(preference=PrefRaw, Pairs) -> true ; PrefRaw = "fastest" ),
             json_atom(StartRaw, Start), json_atom(DestRaw, Destination), json_atom(PrefRaw, Preference),
             get_route_steps_and_reply(Start, Destination, Preference)
           )
        ; reply_json_dict(_{ok:true, message:"POST JSON with start,destination,preference to receive step-by-step directions."})
        )
       )
    ; reply_json_dict(_{ok:true, message:"POST JSON with start,destination,preference to receive step-by-step directions."})
    ).

% Helper to unify step retrieval logic used by GET and POST handlers.
get_route_steps_and_reply(Start, Destination, Preference) :-
    ( \+ coordinates(Start,_,_) -> reply_json_dict(_{ok:false, message:"Unknown start location."})
    ; \+ coordinates(Destination,_,_) -> reply_json_dict(_{ok:false, message:"Unknown destination location."})
    ; ( catch(osrm_route(Start, Destination, Preference, _P, _Dist, _Min, _Geometry, Steps), _E, fail)
        -> reply_json_dict(_{ok:true, steps:Steps})
        ; ( google_api_key(_Key), catch(google_route_steps(Start, Destination, Preference, StepsG), _E2, fail)
            -> reply_json_dict(_{ok:true, steps:StepsG})
            ; ( a_star(Start, Destination, Preference, Path) -> local_route_steps(Path, StepsLocal), reply_json_dict(_{ok:true, steps:StepsLocal}) ; reply_json_dict(_{ok:false, message:"No route available."})
              )
          )
      )
    ).

% Wrap the POST handling in a catch so any unexpected server-side error
% returns a friendly JSON error instead of an HTTP 500 with a long trace.
details_api(Request) :-
    catch(details_api_post(Request), Err,
          ( message_to_string(Err, Msg), reply_json_dict(_{ok:false, message:Msg}) ) ).

details_api_post(Request) :-
    ( catch(http_read_json_dict(Request, Data), E1, throw(E1))
    -> true
    ; reply_json_dict(_{ok:false, message:"Bad request: expecting JSON POST body."}), !, fail
    ),
    % Accept either coordinate objects (start_coord/destination_coord) or string names (start/destination).
    ( get_dict(start_coord, Data, SC0) -> SC = SC0 ; SC = null ),
    ( get_dict(destination_coord, Data, DC0) -> DC = DC0 ; DC = null ),
    ( get_dict(preference, Data, PrefRaw) -> json_atom(PrefRaw, Preference) ; Preference = fastest ),
    ( is_dict(SC)
    -> ( ( get_dict(lat, SC, SL), get_dict(lon, SC, SLon) -> true ; ( get_dict(latitude, SC, SL), get_dict(longitude, SC, SLon) ) ),
        nearest_node(SL, SLon, StartNode), Start = StartNode
      )
    ; ( get_dict(start, Data, StartRaw) -> json_atom(StartRaw, Start) ; Start = _ )
    ),
    ( is_dict(DC)
    -> ( ( get_dict(lat, DC, DL), get_dict(lon, DC, DLon) -> true ; ( get_dict(latitude, DC, DL), get_dict(longitude, DC, DLon) ) ),
        nearest_node(DL, DLon, DestNode), Destination = DestNode
      )
    ; ( get_dict(destination, Data, DestRaw) -> json_atom(DestRaw, Destination) ; Destination = _ )
    ),
    ( \+ coordinates(Start,_,_) -> reply_json_dict(_{ok:false, message:"Unknown start location."})
    ; \+ coordinates(Destination,_,_) -> reply_json_dict(_{ok:false, message:"Unknown destination location."})
    ; ( catch(osrm_route(Start, Destination, Preference, _P, _Dist, _Min, _Geometry, Steps), E2, throw(E2))
      -> reply_json_dict(_{ok:true, steps:Steps})
      ; ( google_api_key(_Key)
       -> ( catch(google_route_steps(Start, Destination, Preference, StepsG), E3, throw(E3))
          -> reply_json_dict(_{ok:true, steps:StepsG})
          ; true
          )
       ; true
       ),
       ( a_star(Start, Destination, Preference, Path)
       -> local_route_steps(Path, StepsLocal), reply_json_dict(_{ok:true, steps:StepsLocal})
       ; reply_json_dict(_{ok:false, message:"No route available."})
       )
      )
    ).

% google_route_steps(+Start,+Destination,+Preference,-Steps)
% Extracts step summaries from Google Directions JSON.
google_route_steps(Start, Destination, Preference, Steps) :-
    google_api_key(Key),
    atom_string(Start, StartS0), atom_string(Destination, DestS0),
    maplist(replace_underscore_with_space, [StartS0, DestS0], [StartAddr, DestAddr]),
    uri_encoded(query_value, StartAddr, EncStart), uri_encoded(query_value, DestAddr, EncDest),
    ( Preference == fastest -> TrafficOpt = '&departure_time=now' ; TrafficOpt = '' ),
    format(string(URL),
           'https://maps.googleapis.com/maps/api/directions/json?origin=~w&destination=~w&mode=driving~w&key=~w',
           [EncStart, EncDest, TrafficOpt, Key]),
    http_open(URL, Stream, [timeout(10), request_header('User-Agent','SmartRouteFinder/1.0')]), json_read_dict(Stream, Json), close(Stream),
    Json.status == "OK", Json.routes \= [],
    Json.routes = [Route|_], Legs = Route.legs,
    findall(_{instruction:Instr, distance:Dist, duration:Dur, name:Name},
            ( member(Leg, Legs), get_dict(steps, Leg, Steps0), member(Step, Steps0),
              ( get_dict(html_instructions, Step, HI) -> strip_html(HI, Instr) ; Instr = "" ),
              ( get_dict(distance, Step, D) -> Dist = D.value ; Dist = 0 ),
              ( get_dict(duration, Step, Du) -> Dur = Du.value ; Dur = 0 ),
              ( get_dict(name, Step, Name) -> true ; Name = "" )
            ), Steps).

% strip_html(+Html, -Text) - very small sanitizer to remove simple tags from html_instructions
strip_html(Html, Text) :-
    atom(Html) -> atom_string(Html, S),
    % remove tags naively
    re_replace("<[^>]+>"/g, "", S, Clean),
    string_trim(Clean, Text), !.
strip_html(_, "").

% local_route_steps(+Path, -Steps)
% Create simple step summaries from local graph edges.
local_route_steps(Path, Steps) :-
    findall(_{from:From, to:To, instruction:Instr, distance:Dist, duration:Dur},
            ( append(_, [From,To|_], Path), available_road(From,To,Dist,Dur),
              format(string(Instr), "Drive from ~w to ~w", [From,To])
            ), Steps).


% path_geometry(+Path, -Geometry)
% Converts a list of node atoms (Path) into a list of latitude/longitude pairs
% that can be plotted on a web map. The demo network uses small integer grid
% coordinates; these are mapped into lat/lon space by applying a simple linear
% transform. For a production system you should use real coordinates (WGS84).
path_geometry(Path, Geometry) :-
    maplist(node_to_latlon, Path, Geometry).

% node_to_latlon(+NodeAtom, -Point)
% Point is a dict with lat and lon keys, both numbers.
node_to_latlon(Node, _{lat:Lat, lon:Lon}) :-
    atom(Node), atom_string(Node, Ns),
    ( coordinates(Node, X, Y) -> true ; ( normalize_name(Ns, Normal), atom_string(AN, Normal), coordinates(AN, X, Y) ) ),
    grid_to_latlon(X, Y, Lat, Lon).

% grid_to_latlon(+X, +Y, -Lat, -Lon)
% Maps internal grid coordinates to approximate WGS84 lat/lon for demo rendering.
% Adjust BASE_LAT/LON and SCALE to move/zoom the overlay on the map.
grid_to_latlon(X, Y, Lat, Lon) :-
    % Base point roughly centered on Colombo
    BASE_LAT = 6.9271,
    BASE_LON = 79.8612,
    SCALE = 0.02, % degrees per grid unit (approx). Tweak for better fit.
    Lat is BASE_LAT - Y * SCALE,
    Lon is BASE_LON + X * SCALE.


a_star(Start, Destination, Preference, Path) :-
    heuristic(Start, Destination, Preference, InitialEstimate),
    empty_heap(Empty),
    add_to_heap(Empty, InitialEstimate, state(Start, 0, [Start]), Open),
    search(Open, Destination, Preference, Path).

search(Open, Destination, _Preference, Path) :-
    get_from_heap(Open, _, state(Destination, _, ReversedPath), _),
    reverse(ReversedPath, Path).
search(Open, Destination, Preference, Path) :-
    get_from_heap(Open, _, state(Current, CostSoFar, ReversedPath), Remaining),
    Current \== Destination,
    findall(Score-state(Next, NextCost, [Next|ReversedPath]),
            ( available_road(Current, Next, Distance, Minutes),
              \+ member(Next, ReversedPath),
              travel_cost(Preference, Distance, Minutes, StepCost),
              NextCost is CostSoFar + StepCost,
              heuristic(Next, Destination, Preference, Estimate),
              Score is NextCost + Estimate
            ),
            Successors),
    add_successors(Successors, Remaining, UpdatedOpen),
    search(UpdatedOpen, Destination, Preference, Path).

add_successors([], Open, Open).
add_successors([Score-State|Rest], Open0, Open) :-
    add_to_heap(Open0, Score, State, Open1),
    add_successors(Rest, Open1, Open).

available_road(From, To, Distance, Minutes) :-
    ( road(From, To, Distance, Minutes) ; road(To, From, Distance, Minutes) ),
    \+ blocked_between(From, To).

blocked_between(First, Second) :-
    blocked_road(First, Second) ; blocked_road(Second, First).

travel_cost(fastest, _Distance, Minutes, Minutes).
travel_cost(shortest, Distance, _Minutes, Distance).

% nearest_node(+Lat, +Lon, -Node)
% Find the nearest graph node (by geographic distance in lat/lon space) to a
% supplied coordinate pair. This is used when the frontend provides a raw
% start_coord/destination_coord so the local A* fallback can map them to the
% demo graph nodes.
nearest_node(Lat, Lon, Node) :-
    findall(D2-N,
            ( coordinates(N,X,Y), grid_to_latlon(X,Y,NLAT,NLON), D is Lat - NLAT, D2 is D*D + (Lon - NLON)*(Lon - NLON) ),
            Pairs),
    sort(Pairs, Sorted),
    Sorted = [ _-Node | _ ].

heuristic(From, To, fastest, Estimate) :-
    straight_line_distance(From, To, Distance),
    Estimate is Distance * 2.
heuristic(From, To, shortest, Estimate) :-
    straight_line_distance(From, To, Estimate).

straight_line_distance(From, To, Distance) :-
    coordinates(From, X1, Y1),
    coordinates(To, X2, Y2),
    Distance is sqrt((X1-X2)^2 + (Y1-Y2)^2).

path_metrics([_], 0, 0).
path_metrics([From, To|Rest], Distance, Minutes) :-
    available_road(From, To, FirstDistance, FirstMinutes),
    path_metrics([To|Rest], RemainingDistance, RemainingMinutes),
    Distance is FirstDistance + RemainingDistance,
    Minutes is FirstMinutes + RemainingMinutes.

% Simple server-side logging to a file for diagnostics. Appends a one-line
% entry with a timestamp and the supplied term (converted to string).
% --- FIX (warning @ line 730): File from blocked_roads_file(File) was bound
% but never used again in this clause (LogPath is built separately below).
% Renamed to _File to mark it as intentionally unused; behavior unchanged.
log_server_event(Term) :-
    blocked_roads_file(_File),
    % Keep runtime diagnostics separate from source files.
    atomic_list_concat(['backend','logs','server.log'], '/', LogPath),
    get_time(TS), format_time(atom(TimeStr), '%Y-%m-%dT%H:%M:%SZ', TS),
    message_to_string(Term, Msg),
    setup_call_cleanup(
        open(LogPath, append, Out, [type(text)]),
        ( format(Out, '~w ~w~n', [TimeStr, Msg]) ),
        close(Out)
    ).