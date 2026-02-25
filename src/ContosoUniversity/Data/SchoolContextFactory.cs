using Microsoft.EntityFrameworkCore;
using System;
using System.Configuration;

namespace ContosoUniversity.Data
{
    public static class SchoolContextFactory
    {
        public static SchoolContext Create()
        {
            // Prefer SQLSERVER_CONNECTION_STRING env var (required in containers/ACA)
            var connectionString = Environment.GetEnvironmentVariable("SQLSERVER_CONNECTION_STRING")
                                   ?? ConfigurationManager.ConnectionStrings["DefaultConnection"].ConnectionString;

            var optionsBuilder = new DbContextOptionsBuilder<SchoolContext>();
            optionsBuilder.UseSqlServer(connectionString);
            
            return new SchoolContext(optionsBuilder.Options);
        }
    }
}
