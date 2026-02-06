CREATE TABLE [rpt].[AccessDelta] (
  [RunTS]      DATETIME2     NOT NULL CONSTRAINT [DF_AccessDelta_RunTS] DEFAULT (SYSUTCDATETIME()),
  [EmployeeID] NVARCHAR(50)  NOT NULL,
  [CardNumber] NVARCHAR(50)  NULL,
  [Action]     NVARCHAR(40)  NOT NULL,
  [Reason]     NVARCHAR(400) NULL,
  CONSTRAINT [PK_rpt_AccessDelta] PRIMARY KEY CLUSTERED ([RunTS],[EmployeeID])
);
