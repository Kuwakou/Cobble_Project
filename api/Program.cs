using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Data.SqlClient;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

// --- JWT authentication middleware (§5) ---
var jwtKey = builder.Configuration["Jwt:Key"];
if (string.IsNullOrWhiteSpace(jwtKey))
    throw new InvalidOperationException("Jwt:Key is not configured. Set Jwt__Key.");

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer           = true,
            ValidateAudience         = true,
            ValidateLifetime         = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer              = builder.Configuration["Jwt:Issuer"],
            ValidAudience            = builder.Configuration["Jwt:Audience"],
            IssuerSigningKey         = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey))
        };
    });

builder.Services.AddAuthorization();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// §5: health endpoint must return HTTP 200
app.MapGet("/health", () => Results.Ok(new
{
    status  = "healthy",
    service = "cobble-api",
    utc     = DateTime.UtcNow
}));

// Proves SQL is reachable from the API over app_net (§7 evidence)
app.MapGet("/health/db", async (IConfiguration cfg) =>
{
    try
    {
        await using var conn = new SqlConnection(cfg.GetConnectionString("Default"));
        await conn.OpenAsync();
        await using var cmd = new SqlCommand("SELECT COUNT(*) FROM dbo.HealthProbe;", conn);
        var rows = (int)(await cmd.ExecuteScalarAsync() ?? 0);

        return Results.Ok(new
        {
            status          = "healthy",
            server          = conn.DataSource,
            database        = conn.Database,
            healthProbeRows = rows
        });
    }
    catch (Exception ex)
    {
        return Results.Json(new { status = "unhealthy", error = ex.Message }, statusCode: 503);
    }
});

// Proves the JWT middleware is actually wired: 401 without a valid bearer token
app.MapGet("/secure/ping", () => Results.Ok(new { message = "token accepted" }))
   .RequireAuthorization();

app.Run();
