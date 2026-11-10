FROM oven/bun:1.2.21
WORKDIR /app
COPY d4t_smoke_reader.js /app/d4t_smoke_reader.js
CMD ["bun","/app/d4t_smoke_reader.js"]
