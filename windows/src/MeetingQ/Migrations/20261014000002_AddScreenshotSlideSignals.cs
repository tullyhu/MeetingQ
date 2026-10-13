using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace MeetingQ.Migrations
{
    /// <inheritdoc />
    public partial class AddScreenshotSlideSignals : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(name: "KeyDates",         table: "Screenshots", type: "TEXT", nullable: true);
            migrationBuilder.AddColumn<string>(name: "SlideDecisions",   table: "Screenshots", type: "TEXT", nullable: true);
            migrationBuilder.AddColumn<string>(name: "SlideActionItems", table: "Screenshots", type: "TEXT", nullable: true);
            migrationBuilder.AddColumn<string>(name: "ChartType",        table: "Screenshots", type: "TEXT", nullable: true);
            migrationBuilder.AddColumn<string>(name: "ChartInsight",     table: "Screenshots", type: "TEXT", nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(name: "KeyDates",         table: "Screenshots");
            migrationBuilder.DropColumn(name: "SlideDecisions",   table: "Screenshots");
            migrationBuilder.DropColumn(name: "SlideActionItems", table: "Screenshots");
            migrationBuilder.DropColumn(name: "ChartType",        table: "Screenshots");
            migrationBuilder.DropColumn(name: "ChartInsight",     table: "Screenshots");
        }
    }
}
