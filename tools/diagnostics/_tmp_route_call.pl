:- consult('backend/smart_route_api.pl').

main :-
    open_string('{"start":"kelaniya","destination":"colombo_fort","preference":"fastest"}', Stream),
    Request = [
        method(post),
        input(Stream),
        request_uri('/api/route'),
        path('/api/route'),
        content_type('application/json'),
        content_length(60),
        host(localhost),
        port(8080),
        protocol(http),
        peer(ip(127,0,0,1))
    ],
    route_api(Request),
    writeln('done'),
    halt.
