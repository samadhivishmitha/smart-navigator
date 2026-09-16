FROM swipl:stable

WORKDIR /app

COPY . .

EXPOSE 8080

CMD ["swipl", "-q", "-s", "app_server.pl", "-g", "start_server"]
