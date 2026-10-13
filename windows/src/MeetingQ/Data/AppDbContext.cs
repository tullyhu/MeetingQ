using System.IO;
using Microsoft.EntityFrameworkCore;
using MeetingQ.Models;

namespace MeetingQ.Data;

public class AppDbContext : DbContext
{
    public DbSet<MeetingSession> Sessions { get; set; }
    public DbSet<Topic> Topics { get; set; }
    public DbSet<Transcript> Transcripts { get; set; }
    public DbSet<Screenshot> Screenshots { get; set; }
    public DbSet<Decision> Decisions { get; set; }
    public DbSet<Question> Questions { get; set; }
    public DbSet<ActionItem> ActionItems { get; set; }
    public DbSet<VoiceprintSpeaker> VoiceprintSpeakers { get; set; }
    public DbSet<MeetingTheme> MeetingThemes { get; set; }

    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        modelBuilder.Entity<MeetingSession>(entity =>
        {
            entity.HasKey(e => e.SessionId);
            entity.Property(e => e.Status).HasConversion<string>();
            entity.HasMany(e => e.Topics)
                  .WithOne(t => t.Session)
                  .HasForeignKey(t => t.SessionId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasMany(e => e.Screenshots)
                  .WithOne(s => s.Session)
                  .HasForeignKey(s => s.SessionId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne(e => e.Theme)
                  .WithMany(t => t.Sessions)
                  .HasForeignKey(e => e.ThemeId)
                  .OnDelete(DeleteBehavior.SetNull);
        });

        modelBuilder.Entity<MeetingTheme>(entity =>
        {
            entity.HasKey(e => e.ThemeId);
        });

        modelBuilder.Entity<Topic>(entity =>
        {
            entity.HasKey(e => e.TopicId);
            entity.HasMany(e => e.Transcripts)
                  .WithOne(t => t.Topic)
                  .HasForeignKey(t => t.TopicId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasMany(e => e.Decisions)
                  .WithOne(d => d.Topic)
                  .HasForeignKey(d => d.TopicId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasMany(e => e.Questions)
                  .WithOne(q => q.Topic)
                  .HasForeignKey(q => q.TopicId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasMany(e => e.ActionItems)
                  .WithOne(a => a.Topic)
                  .HasForeignKey(a => a.TopicId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<Question>(entity =>
        {
            entity.Property(e => e.QuestionType).HasConversion<string>();
            entity.Property(e => e.Status).HasConversion<string>();
        });
    }

    public static string GetDatabasePath()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var dir = Path.Combine(localAppData, "MeetingQ");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, "meetingq.db");
    }
}
