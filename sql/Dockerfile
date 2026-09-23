FROM mcr.microsoft.com/mssql/server:2022-latest
USER root
COPY entrypoint.sh /usr/src/app/
COPY init/ /usr/src/app/init/
COPY tests/ /usr/src/app/tests/
RUN chmod +x /usr/src/app/entrypoint.sh && chown -R mssql:root /usr/src/app
USER mssql
CMD ["/usr/src/app/entrypoint.sh"]
