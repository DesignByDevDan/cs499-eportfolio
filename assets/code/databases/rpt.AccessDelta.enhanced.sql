/*
CS 499 – Milestone Four (Databases Enhancement)
Artifact: C-Cure-Reporting-DB (SQL Server / SSDT)
File: rpt.AccessDelta.sql (enhanced)

Enhancement goals implemented in this script:
1) Stronger relational integrity via reference tables + foreign keys
2) Audit-ready eligibility history tracking (ops.EligibilityHistory)
3) Indexing aligned to delta/reporting access patterns
*/

-- =========================
-- 1) Reference / lookup data
-- =========================
CREATE SCHEMA ref;
GO

CREATE TABLE ref.AccessActionType (
    ActionTypeCode NVARCHAR(40) NOT NULL,
    ActionTypeName NVARCHAR(80) NOT NULL,
    IsActive       BIT          NOT NULL CONSTRAINT DF_ref_AccessActionType_IsActive DEFAULT (1),
    CONSTRAINT PK_ref_AccessActionType PRIMARY KEY CLUSTERED (ActionTypeCode),
    CONSTRAINT UQ_ref_AccessActionType_Name UNIQUE (ActionTypeName)
);
GO

-- Optional seed values (adjust to your integration vocabulary)
INSERT INTO ref.AccessActionType (ActionTypeCode, ActionTypeName)
VALUES
    (N'GRANT',   N'Grant Access'),
    (N'REVOKE',  N'Revoke Access'),
    (N'NOCHANGE',N'No Change')
;
GO

-- =========================
-- 2) Core operational tables
-- =========================
CREATE SCHEMA ops;
GO

CREATE TABLE ops.Person (
    PersonID     INT IDENTITY(1,1) NOT NULL,
    EmployeeID   NVARCHAR(50)       NOT NULL,
    CardNumber   NVARCHAR(50)       NULL,
    CreatedTS    DATETIME2          NOT NULL CONSTRAINT DF_ops_Person_CreatedTS DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ops_Person PRIMARY KEY CLUSTERED (PersonID),
    CONSTRAINT UQ_ops_Person_EmployeeID UNIQUE (EmployeeID)
);
GO

CREATE TABLE ops.Eligibility (
    PersonID       INT        NOT NULL,
    Eligible       BIT        NOT NULL,
    EffectiveTS    DATETIME2  NOT NULL,
    LastCheckedTS  DATETIME2  NOT NULL CONSTRAINT DF_ops_Eligibility_LastCheckedTS DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ops_Eligibility PRIMARY KEY CLUSTERED (PersonID),
    CONSTRAINT FK_ops_Eligibility_Person FOREIGN KEY (PersonID) REFERENCES ops.Person(PersonID),
    CONSTRAINT CK_ops_Eligibility_EffectiveTS CHECK (EffectiveTS <= SYSUTCDATETIME())
);
GO

CREATE TABLE ops.EligibilityHistory (
    EligibilityHistoryID BIGINT IDENTITY(1,1) NOT NULL,
    PersonID             INT                 NOT NULL,
    OldEligible          BIT                 NOT NULL,
    NewEligible          BIT                 NOT NULL,
    ChangedTS            DATETIME2           NOT NULL CONSTRAINT DF_ops_EligibilityHistory_ChangedTS DEFAULT (SYSUTCDATETIME()),
    Reason               NVARCHAR(400)       NULL,
    CONSTRAINT PK_ops_EligibilityHistory PRIMARY KEY CLUSTERED (EligibilityHistoryID),
    CONSTRAINT FK_ops_EligibilityHistory_Person FOREIGN KEY (PersonID) REFERENCES ops.Person(PersonID),
    CONSTRAINT CK_ops_EligibilityHistory_ChangedTS CHECK (ChangedTS <= SYSUTCDATETIME())
);
GO

-- Indexes to support common lookups/reporting
CREATE INDEX IX_ops_Person_EmployeeID ON ops.Person(EmployeeID);
GO
CREATE INDEX IX_ops_EligibilityHistory_PersonID_ChangedTS ON ops.EligibilityHistory(PersonID, ChangedTS DESC);
GO

-- ==========================================
-- 3) Reporting delta table (original artifact)
--    Enhanced with integrity + performance
-- ==========================================
CREATE SCHEMA rpt;
GO

CREATE TABLE rpt.AccessDelta (
    RunTS      DATETIME2     NOT NULL CONSTRAINT DF_AccessDelta_RunTS DEFAULT (SYSUTCDATETIME()),
    EmployeeID NVARCHAR(50)  NOT NULL,
    CardNumber NVARCHAR(50)  NULL,
    ActionType NVARCHAR(40)  NOT NULL, -- renamed from [Action] for clarity + keyword avoidance
    Reason     NVARCHAR(400) NULL,

    CONSTRAINT PK_rpt_AccessDelta PRIMARY KEY CLUSTERED (RunTS, EmployeeID),

    -- Prevent duplicate deltas within the same run for the same user/action
    CONSTRAINT UQ_rpt_AccessDelta_Run_Employee_Action UNIQUE (RunTS, EmployeeID, ActionType),

    -- Enforce valid actions through reference data
    CONSTRAINT FK_rpt_AccessDelta_ActionType FOREIGN KEY (ActionType) REFERENCES ref.AccessActionType(ActionTypeCode)
);
GO

-- Fast filtering by EmployeeID (common in troubleshooting / targeted replays)
CREATE INDEX IX_rpt_AccessDelta_EmployeeID_RunTS ON rpt.AccessDelta(EmployeeID, RunTS DESC);
GO

-- ==========================================
-- 4) Stored procedure: Eligibility update w/ history
--    (Implements the pseudocode from the plan)
-- ==========================================
CREATE OR ALTER PROCEDURE ops.usp_UpsertEligibility
    @EmployeeID  NVARCHAR(50),
    @NewEligible BIT,
    @Reason      NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PersonID INT;

    SELECT @PersonID = PersonID
    FROM ops.Person
    WHERE EmployeeID = @EmployeeID;

    IF @PersonID IS NULL
    BEGIN
        INSERT INTO ops.Person(EmployeeID)
        VALUES (@EmployeeID);

        SET @PersonID = SCOPE_IDENTITY();
    END

    IF NOT EXISTS (SELECT 1 FROM ops.Eligibility WHERE PersonID = @PersonID)
    BEGIN
        INSERT INTO ops.Eligibility (PersonID, Eligible, EffectiveTS)
        VALUES (@PersonID, @NewEligible, SYSUTCDATETIME());
    END
    ELSE
    BEGIN
        DECLARE @OldEligible BIT;

        SELECT @OldEligible = Eligible
        FROM ops.Eligibility
        WHERE PersonID = @PersonID;

        IF @OldEligible <> @NewEligible
        BEGIN
            INSERT INTO ops.EligibilityHistory (PersonID, OldEligible, NewEligible, Reason)
            VALUES (@PersonID, @OldEligible, @NewEligible, @Reason);

            UPDATE ops.Eligibility
            SET Eligible = @NewEligible,
                EffectiveTS = SYSUTCDATETIME(),
                LastCheckedTS = SYSUTCDATETIME()
            WHERE PersonID = @PersonID;
        END
        ELSE
        BEGIN
            UPDATE ops.Eligibility
            SET LastCheckedTS = SYSUTCDATETIME()
            WHERE PersonID = @PersonID;
        END
    END
END;
GO
